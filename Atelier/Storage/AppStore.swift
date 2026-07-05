// SPDX-License-Identifier: MIT
import Foundation
import Observation
import GRDB
import os

/// Reactive façade over the DB. Holds the current view of workspaces + their projects,
/// kept up-to-date via GRDB `ValueObservation`. SwiftUI views read it directly.
///
/// Mutations (`create*`, `delete*`, `rename*`, …) are async — they wait for the write
/// to commit, and the observation propagates the change back into `workspaces` /
/// `projectsByWorkspace`.
@MainActor
@Observable
final class AppStore {
    private let logger = Logger(subsystem: "app.atelier", category: "store")
    private let db = Database.shared

    private(set) var workspaces: [Workspace] = []
    private(set) var projectsByWorkspace: [String: [Project]] = [:]
    private(set) var tasksByProject: [String: [AtelierTask]] = [:]
    private(set) var tasksByFeature: [String: [AtelierTask]] = [:]   // O(1) feature-scoped lookups
    private(set) var featuresByProject: [String: [Feature]] = [:]
    private(set) var featuresById: [String: Feature] = [:]           // O(1) featureByID
    private(set) var chatRooms: [ChatRoom] = []
    private(set) var isLoaded: Bool = false

    /// Live, EPHEMERAL per-task build progress reported by workers over the MCP
    /// capability bridge. Not persisted (no migration, no git/frontmatter churn);
    /// resets on relaunch. SwiftUI reads `taskProgress[taskId]` for a live %.
    struct TaskProgress: Sendable, Equatable {
        var pct: Int
        var note: String?
        var updatedAt: Date
    }
    private(set) var taskProgress: [String: TaskProgress] = [:]

    /// Records a worker's progress ping (clamped 0–100). Observation-driven → the
    /// kanban updates live. No DB write.
    func reportProgress(taskId: String, pct: Int, note: String?) {
        taskProgress[taskId] = TaskProgress(pct: max(0, min(100, pct)),
                                            note: note,
                                            updatedAt: Date())
    }

    /// Clears a task's transient progress (e.g. once it merges/completes).
    func clearProgress(taskId: String) {
        taskProgress[taskId] = nil
    }

    /// Ephemeral block reasons reported via `task_signal_blocked` (the status flip
    /// to .blocked is the durable signal; the reason is transient, no migration).
    private(set) var taskBlockedReason: [String: String] = [:]
    func setBlockedReason(taskId: String, reason: String) { taskBlockedReason[taskId] = reason }
    func clearBlockedReason(taskId: String) { taskBlockedReason[taskId] = nil }

    /// Bumped whenever the MCP bridge writes a feature's living brief.md, so an
    /// open PreparePromptView preview reloads live (keyed by chat-room id). Not
    /// persisted — purely a UI refresh signal.
    private(set) var briefRevision: [String: Int] = [:]
    func bumpBriefRevision(roomId: String) { briefRevision[roomId, default: 0] += 1 }

    /// Ephemeral warnings from the last `createTasks` attachment routing (unmatched
    /// decomposer-assigned names, failed copies, ambiguous duplicate basenames) —
    /// surfaced in the tasks UI so a task can never silently lose its mockup. Keyed by
    /// featureId (the loose Fill-Kanban flow uses ""), so a decompose in one feature can't
    /// clobber the banner another feature is showing. Reset per key on each `createTasks`.
    private(set) var attachmentRoutingWarnings: [String: [String]] = [:]
    /// Routing warnings from the most recent decompose into `featureId` (empty if none).
    func attachmentWarnings(featureId: String) -> [String] { attachmentRoutingWarnings[featureId] ?? [] }

    private var observationTask: Task<Void, Never>?

    init() {
        startObserving()
    }

    private func startObserving() {
        let wsObservation = ValueObservation.tracking { db in
            try Workspace.order(Workspace.Columns.createdAt.asc).fetchAll(db)
        }
        let projObservation = ValueObservation.tracking { db in
            try Project.order(Project.Columns.createdAt.asc).fetchAll(db)
        }
        let taskObservation = ValueObservation.tracking { db in
            try AtelierTask.order(AtelierTask.Columns.createdAt.asc).fetchAll(db)
        }

        observationTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        for try await ws in wsObservation.values(in: self.db.dbPool) {
                            await MainActor.run {
                                self.workspaces = ws
                                self.isLoaded = true
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.logger.error("workspace observation failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        for try await projects in projObservation.values(in: self.db.dbPool) {
                            let grouped = Dictionary(grouping: projects, by: \.workspaceId)
                            await MainActor.run { self.projectsByWorkspace = grouped }
                        }
                    } catch {
                        await MainActor.run {
                            self.logger.error("project observation failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        for try await tasks in taskObservation.values(in: self.db.dbPool) {
                            let grouped = Dictionary(grouping: tasks, by: \.projectId)
                            let byFeature = Dictionary(grouping: tasks.filter { $0.featureId != nil },
                                                       by: { $0.featureId! })
                            await MainActor.run {
                                self.tasksByProject = grouped
                                self.tasksByFeature = byFeature
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.logger.error("task observation failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    let obs = ValueObservation.tracking { db in
                        try ChatRoom.order(ChatRoom.Columns.updatedAt.desc).fetchAll(db)
                    }
                    do {
                        for try await rooms in obs.values(in: self.db.dbPool) {
                            await MainActor.run { self.chatRooms = rooms }
                        }
                    } catch {
                        await MainActor.run {
                            self.logger.error("chat observation failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    let obs = ValueObservation.tracking { db in
                        try Feature.order(Feature.Columns.createdAt.asc).fetchAll(db)
                    }
                    do {
                        for try await features in obs.values(in: self.db.dbPool) {
                            let grouped = Dictionary(grouping: features, by: \.projectId)
                            let byId = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                            await MainActor.run {
                                self.featuresByProject = grouped
                                self.featuresById = byId
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.logger.error("feature observation failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Chat rooms

    func createChatRoom(model: String = "claude-sonnet-4-6") async throws -> ChatRoom {
        let room = ChatRoom.newDraft(model: model)
        try await db.write { db in
            var copy = room
            try copy.insert(db)
        }
        return room
    }

    func updateChatRoom(_ room: ChatRoom) async throws {
        var draft = room
        draft.updatedAt = Date()
        let final = draft
        try await db.write { db in
            var c = final
            try c.update(db)
        }
    }

    func deleteChatRoom(_ room: ChatRoom) async throws {
        try await db.write { db in
            _ = try ChatRoom.filter(ChatRoom.Columns.id == room.id).deleteAll(db)
        }
        // Best-effort cleanup of the scratch dir on disk.
        try? FileManager.default.removeItem(atPath: room.scratchPath)
    }

    func chatRoom(id: String) -> ChatRoom? {
        chatRooms.first(where: { $0.id == id })
    }

    /// Free-form chats only — excludes Prepare Prompt briefs (which live in the project board).
    var freeFormChats: [ChatRoom] { chatRooms.filter { !$0.isBrief } }

    /// Prepare Prompt briefs for a project, most-recent first (observation already sorts by updatedAt desc).
    func briefRooms(in projectId: String) -> [ChatRoom] {
        chatRooms.filter { $0.isBrief && $0.projectId == projectId }
    }

    @discardableResult
    func createBriefRoom(projectId: String, model: String = "claude-sonnet-4-6") async throws -> ChatRoom {
        let room = ChatRoom.newBriefDraft(projectId: projectId, model: model)
        try await db.write { db in
            var copy = room
            try copy.insert(db)
        }
        return room
    }

    // MARK: - Workspace mutations

    func createWorkspace(name: String, color: String = Workspace.suggestedColors[0]) async throws -> Workspace {
        let ws = Workspace.newDraft(name: name, color: color)
        try await db.write { db in
            var copy = ws
            try copy.insert(db)
        }
        return ws
    }

    func renameWorkspace(_ ws: Workspace, to newName: String) async throws {
        try await db.write { db in
            try Workspace
                .filter(Workspace.Columns.id == ws.id)
                .updateAll(db, Workspace.Columns.name.set(to: newName))
        }
    }

    func recolorWorkspace(_ ws: Workspace, to color: String) async throws {
        try await db.write { db in
            try Workspace
                .filter(Workspace.Columns.id == ws.id)
                .updateAll(db, Workspace.Columns.color.set(to: color))
        }
    }

    func deleteWorkspace(_ ws: Workspace) async throws {
        try await db.write { db in
            _ = try Workspace.filter(Workspace.Columns.id == ws.id).deleteAll(db)
        }
    }

    // MARK: - Project mutations

    func projects(in workspaceId: String) -> [Project] {
        projectsByWorkspace[workspaceId] ?? []
    }

    func projectByPath(_ path: String) -> Project? {
        projectsByWorkspace.values.flatMap { $0 }.first(where: { $0.path == path })
    }

    func addProject(workspace: Workspace,
                    name: String,
                    path: String,
                    profileId: String? = nil,
                    defaultModel: String? = nil) async throws -> Project {
        var draft = Project.newDraft(workspaceId: workspace.id, name: name, path: path)
        draft.profileId = profileId
        if let defaultModel { draft.defaultModel = defaultModel }
        let p = draft
        try await db.write { db in
            var copy = p
            try copy.insert(db)
        }
        // Pull in any tasks that already live in `<repo>/backlog/tasks/*.md`.
        _ = try? await importTasksFromDisk(project: p)
        return p
    }

    func deleteProject(_ p: Project) async throws {
        try await db.write { db in
            _ = try Project.filter(Project.Columns.id == p.id).deleteAll(db)
        }
    }

    func renameProject(_ p: Project, to newName: String) async throws {
        try await db.write { db in
            try Project
                .filter(Project.Columns.id == p.id)
                .updateAll(db, Project.Columns.name.set(to: newName))
        }
    }

    /// Persists an updated Project row (any field). Caller passes a copy with
    /// the new field values; the row keyed by id is overwritten in full.
    func updateProject(_ p: Project) async throws {
        try await db.write { db in
            var copy = p
            try copy.update(db)
        }
    }

    /// Transactional read-modify-write of a project (reads the committed row inside the txn) so
    /// rapid independent field toggles don't clobber each other off the lagging cache.
    func updateProject(id: String, _ mutate: @escaping @Sendable (inout Project) -> Void) async throws {
        try await db.write { db in
            guard var p = try Project.filter(Project.Columns.id == id).fetchOne(db) else { return }
            mutate(&p)
            try p.update(db)
        }
    }

    func projectByID(_ id: String) -> Project? {
        projectsByWorkspace.values.flatMap { $0 }.first(where: { $0.id == id })
    }

    // MARK: - Features

    /// A project's features, newest first (observation sorts by createdAt asc, so reverse here).
    func features(in projectId: String) -> [Feature] {
        (featuresByProject[projectId] ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func featureByID(_ id: String) -> Feature? { featuresById[id] }

    @discardableResult
    func createFeature(in project: Project, name: String) async throws -> Feature {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Feature name must not be empty")
        let feature = Feature.newDraft(projectId: project.id, name: trimmed)
        try await db.write { db in
            var copy = feature
            try copy.insert(db)
        }
        return feature
    }

    /// Persists an updated Feature row (any field), stamping `updatedAt`.
    func updateFeature(_ feature: Feature) async throws {
        var draft = feature
        draft.updatedAt = Date()
        let final = draft
        try await db.write { db in
            var copy = final
            try copy.update(db)
        }
    }

    /// Transactional read-modify-write of a feature: reads the committed row INSIDE the write txn,
    /// applies `mutate`, and saves — so a concurrent writer touching a different field isn't clobbered
    /// by a full-row overwrite off the (possibly lagging) observation cache. No-op if the row is gone.
    func updateFeature(id: String, _ mutate: @escaping @Sendable (inout Feature) -> Void) async throws {
        try await db.write { db in
            guard var f = try Feature.filter(Feature.Columns.id == id).fetchOne(db) else { return }
            mutate(&f)
            f.updatedAt = Date()
            try f.update(db)
        }
    }

    func deleteFeature(_ feature: Feature) async throws {
        // Detach its tasks (clear featureId in the DB row + `.md` frontmatter) so none dangle at a
        // now-missing feature. Callers should stop any in-flight run for this feature first.
        for var t in tasks(inFeature: feature.id) {
            t.featureId = nil
            try? await updateTask(t)
        }
        try await db.write { db in
            _ = try Feature.filter(Feature.Columns.id == feature.id).deleteAll(db)
        }
        // Clean the feature's shared-files store — otherwise mockups/PDFs are orphaned forever.
        if let project = projectByID(feature.projectId) {
            FeatureAttachments.removeAll(projectRoot: project.path, featureId: feature.id)
        }
    }

    // MARK: - Task queries

    func tasks(in projectId: String) -> [AtelierTask] {
        tasksByProject[projectId] ?? []
    }

    func tasks(in projectId: String, status: AtelierTask.Status) -> [AtelierTask] {
        tasks(in: projectId).filter { $0.status == status }
    }

    /// A feature's tasks (feature-first flow), ordered by id for stable display.
    func tasks(inFeature featureId: String) -> [AtelierTask] {
        (tasksByFeature[featureId] ?? []).sorted { $0.id < $1.id }
    }

    func taskByID(_ id: String) -> AtelierTask? {
        tasksByProject.values.flatMap { $0 }.first(where: { $0.id == id })
    }

    /// Reads the current committed row straight from the DB (not the lagging observation cache),
    /// so read-modify-write chains in a single pipeline never start from a stale base.
    func freshTask(_ id: String) async -> AtelierTask? {
        try? await db.read { db in
            try AtelierTask.filter(AtelierTask.Columns.id == id).fetchOne(db)
        }
    }

    // MARK: - Task mutations

    /// Creates a task on disk (writes `<project>/backlog/tasks/<id>-<slug>.md`) and
    /// indexes it in the DB. The disk file is the source of truth.
    @discardableResult
    func createTask(in project: Project,
                    title: String,
                    priority: AtelierTask.Priority? = nil,
                    workerModel: String? = nil,
                    featureId: String? = nil) async throws -> AtelierTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Task title must not be empty")
        let projectId = project.id
        let model = workerModel ?? project.defaultModel

        // Allocate the id AND insert inside a single write transaction, reading the already-committed
        // ids (not the async observation cache). Rapid/batch creates (e.g. decompose) otherwise all
        // read a stale cache and collide on task.id (SQLite UNIQUE). GRDB serializes writes, so the
        // max-id read + insert are atomic against concurrent creates.
        let draft: AtelierTask = try await db.write { db in
            // task.id is a GLOBAL primary key (unique across the whole table), so allocate against
            // ALL task ids — not just this project's. A new/low-numbered project otherwise regenerates
            // an id (task-001…) that already exists globally → SQLite UNIQUE on task.id.
            let existing = try String.fetchAll(db, sql: "SELECT id FROM task")
            let id = BacklogMD.nextId(existing: existing)
            let mdPath = "backlog/tasks/\(BacklogMD.filename(forId: id, title: trimmed))"
            var d = AtelierTask.newDraft(id: id, projectId: projectId, title: trimmed,
                                         mdPath: mdPath, priority: priority, workerModel: model)
            d.featureId = featureId
            try d.insert(db)
            return d
        }
        // Write the .md file once the row (and its id) is committed.
        try BacklogMD.write(task: draft, to: draft.absoluteMdPath(projectRoot: project.path))
        return draft
    }

    /// Persists a batch of `AIAssistant.TaskDraft`s in two passes: create every task (recording each
    /// draft's ref → real id), then resolve `depends_on` refs to real ids and copy any decomposer-
    /// assigned attachments (matched by filename against `attachmentSources` — e.g. the feature's
    /// shared brief files) into each task's own folder, so the worker physically receives them.
    /// Shared by Fill Kanban and the feature flow's decompose stage. `featureId` stamps every
    /// created task (feature-first flow).
    @discardableResult
    func createTasks(fromDrafts drafts: [AIAssistant.TaskDraft],
                     in project: Project,
                     featureId: String? = nil,
                     attachmentSources: [URL] = []) async throws -> [AtelierTask] {
        var refToId: [String: String] = [:]
        var created: [(draft: AIAssistant.TaskDraft, task: AtelierTask)] = []
        for draft in drafts {
            var task = try await createTask(in: project,
                                            title: draft.title,
                                            priority: draft.priority,
                                            workerModel: draft.workerModel,
                                            featureId: featureId)
            if !draft.descriptionMd.isEmpty { task.descriptionMd = draft.descriptionMd }
            if !draft.labels.isEmpty { task.labels = draft.labels }
            if !draft.descriptionMd.isEmpty || !draft.labels.isEmpty {
                try await updateTask(task)
            }
            if let ref = draft.ref { refToId[ref] = task.id }
            created.append((draft, task))
        }
        // Second pass: deps + assigned attachments in ONE write per task (a split write from
        // the same snapshot would clobber whichever field landed first). File copies run OFF
        // the main actor in one batch, and every routing failure — an assigned name that
        // matches no shared file, or a copy that throws — is surfaced as a warning: a task
        // must never silently lose its mockup.
        var warnings: [String] = []
        for dupe in FeatureAttachments.duplicateBasenames(in: attachmentSources) {
            warnings.append("Several shared files are named “\(dupe)” — only the first can be routed to tasks; rename the others to disambiguate.")
        }
        struct Route { let index: Int; let deps: [String]; let files: [URL]; let unmatched: [String] }
        var routes: [Route] = []
        for (i, entry) in created.enumerated() {
            let deps = entry.draft.dependsOnRefs
                .compactMap { refToId[$0] }
                .filter { $0 != entry.task.id }
            let files = FeatureAttachments.match(names: entry.draft.attachments, in: attachmentSources)
            let matchedNames = Set(files.map { $0.lastPathComponent.lowercased() })
            let unmatched = entry.draft.attachments.filter {
                !matchedNames.contains(($0 as NSString).lastPathComponent.lowercased())
            }
            guard !deps.isEmpty || !files.isEmpty || !unmatched.isEmpty else { continue }
            routes.append(Route(index: i, deps: deps, files: files, unmatched: unmatched))
        }
        // Batch the synchronous copyItem calls off the main actor.
        let projectPath = project.path
        let copyPlan: [(taskId: String, files: [URL])] = routes.map { (created[$0.index].task.id, $0.files) }
        let copyResults: [(relatives: [String], failures: [String])] = await Task.detached(priority: .userInitiated) {
            copyPlan.map { plan in
                var rels: [String] = []
                var fails: [String] = []
                for file in plan.files {
                    do {
                        rels.append(try AttachmentService.attach(sourceURL: file, taskId: plan.taskId,
                                                                 projectRoot: projectPath))
                    } catch {
                        fails.append("\(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (rels, fails)
            }
        }.value
        for (r, route) in routes.enumerated() {
            var t = created[route.index].task
            if !route.deps.isEmpty { t.dependsOn = Array(Set(route.deps)) }
            let (relatives, failures) = copyResults[r]
            for rel in relatives where !t.attachments.contains(rel) { t.attachments.append(rel) }
            if !route.deps.isEmpty || !relatives.isEmpty { try await updateTask(t) }
            for name in route.unmatched {
                warnings.append("“\(t.title)”: assigned file “\(name)” doesn't match any shared file — not delivered to the worker.")
            }
            for failure in failures {
                warnings.append("“\(t.title)”: couldn't copy \(failure)")
            }
        }
        if !warnings.isEmpty {
            logger.warning("attachment routing: \(warnings.joined(separator: " | "), privacy: .public)")
        }
        attachmentRoutingWarnings[featureId ?? ""] = warnings   // reset this scope's warnings every run
        return created.map(\.task)
    }

    /// Re-writes the .md file and updates the DB row.
    func updateTask(_ task: AtelierTask) async throws {
        var updated = task
        updated.updatedAt = Date()

        guard let project = projectByID(task.projectId) else {
            throw NSError(domain: "AppStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project not found for task \(task.id)"
            ])
        }

        let absolutePath = updated.absoluteMdPath(projectRoot: project.path)
        // Preserve any unknown frontmatter keys by re-reading the file first.
        var extras: [String: Any] = [:]
        if let parsed = try? BacklogMD.read(at: absolutePath) {
            extras = parsed.extras
        }
        try BacklogMD.write(task: updated, to: absolutePath, extras: extras)

        let snapshot = updated
        try await db.write { db in
            var copy = snapshot
            try copy.update(db)
        }
    }

    func updateTaskStatus(_ task: AtelierTask, to status: AtelierTask.Status) async throws {
        var t = task
        t.status = status
        try await updateTask(t)
    }

    // MARK: - Attachments

    /// Copies the given file into the task's attachments folder and updates the task
    /// + DB + `.md` frontmatter accordingly. Returns the updated task.
    @discardableResult
    func attachFile(to task: AtelierTask, sourceURL: URL) async throws -> AtelierTask {
        guard let project = projectByID(task.projectId) else {
            throw NSError(domain: "AppStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project not found for task \(task.id)"
            ])
        }
        let relative = try AttachmentService.attach(
            sourceURL: sourceURL,
            taskId: task.id,
            projectRoot: project.path
        )
        var updated = task
        if !updated.attachments.contains(relative) {
            updated.attachments.append(relative)
        }
        try await updateTask(updated)
        return updated
    }

    /// Removes a single attachment from disk + DB + frontmatter.
    @discardableResult
    func detachFile(from task: AtelierTask, relativePath: String) async throws -> AtelierTask {
        guard let project = projectByID(task.projectId) else {
            throw NSError(domain: "AppStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Project not found for task \(task.id)"
            ])
        }
        try AttachmentService.detach(relativePath: relativePath, projectRoot: project.path)
        var updated = task
        updated.attachments.removeAll { $0 == relativePath }
        try await updateTask(updated)
        return updated
    }

    /// Deletes the .md file (moves to archive if you prefer; here we delete outright)
    /// and removes the DB row.
    func deleteTask(_ task: AtelierTask, removeFile: Bool = true) async throws {
        if removeFile, let project = projectByID(task.projectId) {
            let abs = task.absoluteMdPath(projectRoot: project.path)
            try? FileManager.default.removeItem(atPath: abs)
            // Clean the task's attachment folder too (same orphan gap as feature stores).
            let attachmentsDir = URL(fileURLWithPath: project.path)
                .appendingPathComponent(".atelier", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(task.id, isDirectory: true)
            try? FileManager.default.removeItem(at: attachmentsDir)
        }
        try await db.write { db in
            _ = try AtelierTask.filter(AtelierTask.Columns.id == task.id).deleteAll(db)
        }
    }

    /// Scan `<project>/backlog/tasks/*.md`, parse each file and upsert into the DB.
    /// Used after `addProject(...)` and as a manual "Refresh" affordance.
    func importTasksFromDisk(project: Project) async throws -> (added: Int, updated: Int, removed: Int) {
        let fm = FileManager.default
        let tasksDir = URL(fileURLWithPath: project.path)
            .appendingPathComponent("backlog", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        guard fm.fileExists(atPath: tasksDir.path) else {
            return (0, 0, 0)
        }
        let mdFiles: [URL]
        do {
            mdFiles = try fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
        } catch {
            throw error
        }

        var built: [AtelierTask] = []
        for fileURL in mdFiles {
            do {
                let parsed = try BacklogMD.read(at: fileURL.path)
                let relativePath = "backlog/tasks/\(fileURL.lastPathComponent)"
                let task = AtelierTask(
                    id: parsed.id,
                    projectId: project.id,
                    title: parsed.title,
                    status: parsed.status,
                    priority: parsed.priority,
                    labels: parsed.labels,
                    mdPath: relativePath,
                    dependsOn: parsed.dependsOn,
                    workerModel: parsed.workerModel,
                    budgetUsd: parsed.budgetUsd,
                    descriptionMd: parsed.body.isEmpty ? nil : parsed.body,
                    attachments: parsed.attachments,
                    featureId: parsed.featureId,
                    testState: parsed.testState,
                    testSummary: parsed.testSummary,
                    testIntegrity: parsed.testIntegrity,
                    testChangeNote: parsed.testChangeNote,
                    createdAt: parsed.createdAt,
                    updatedAt: parsed.updatedAt
                )
                built.append(task)
            } catch {
                logger.warning("Skipping malformed task file \(fileURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let parsedTasks = built
        let parsedIds = Set(parsedTasks.map(\.id))
        let projectId = project.id

        let counters = try await db.write { db -> (Int, Int, Int) in
            var added = 0
            var updatedCount = 0
            var removed = 0
            let existing = try AtelierTask
                .filter(AtelierTask.Columns.projectId == projectId)
                .fetchAll(db)
            let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

            for t in parsedTasks {
                var copy = t
                if existingById[t.id] != nil {
                    try copy.update(db)
                    updatedCount += 1
                } else {
                    try copy.insert(db)
                    added += 1
                }
            }
            for e in existing where !parsedIds.contains(e.id) {
                _ = try AtelierTask.filter(AtelierTask.Columns.id == e.id).deleteAll(db)
                removed += 1
            }
            return (added, updatedCount, removed)
        }
        return (added: counters.0, updated: counters.1, removed: counters.2)
    }

    // MARK: - Agent persistence

    func insertAgent(_ agent: Agent) async throws {
        let snapshot = agent
        try await db.write { db in
            var copy = snapshot
            try copy.insert(db)
        }
    }

    func updateAgent(_ agent: Agent) async throws {
        let snapshot = agent
        try await db.write { db in
            var copy = snapshot
            try copy.update(db)
        }
    }

    func agentsForTask(_ taskId: String) async throws -> [Agent] {
        try await db.read { db in
            try Agent
                .filter(Agent.Columns.taskId == taskId)
                .order(Agent.Columns.startedAt.desc)
                .fetchAll(db)
        }
    }

    /// All Agent rows. Used by the Usage dashboard for cross-task aggregations.
    func allAgents() async throws -> [Agent] {
        try await db.read { db in
            try Agent.order(Agent.Columns.startedAt.desc).fetchAll(db)
        }
    }
}
