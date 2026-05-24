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
    private(set) var chatRooms: [ChatRoom] = []
    private(set) var isLoaded: Bool = false

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
                            await MainActor.run { self.tasksByProject = grouped }
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

    func projectByID(_ id: String) -> Project? {
        projectsByWorkspace.values.flatMap { $0 }.first(where: { $0.id == id })
    }

    // MARK: - Task queries

    func tasks(in projectId: String) -> [AtelierTask] {
        tasksByProject[projectId] ?? []
    }

    func tasks(in projectId: String, status: AtelierTask.Status) -> [AtelierTask] {
        tasks(in: projectId).filter { $0.status == status }
    }

    func taskByID(_ id: String) -> AtelierTask? {
        tasksByProject.values.flatMap { $0 }.first(where: { $0.id == id })
    }

    // MARK: - Task mutations

    /// Creates a task on disk (writes `<project>/backlog/tasks/<id>-<slug>.md`) and
    /// indexes it in the DB. The disk file is the source of truth.
    @discardableResult
    func createTask(in project: Project,
                    title: String,
                    priority: AtelierTask.Priority? = nil,
                    workerModel: String? = nil) async throws -> AtelierTask {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Task title must not be empty")

        let existingIds = tasks(in: project.id).map(\.id)
        let id = BacklogMD.nextId(existing: existingIds)
        let filename = BacklogMD.filename(forId: id, title: trimmed)
        let mdPath = "backlog/tasks/\(filename)"
        let absolutePath = URL(fileURLWithPath: project.path).appendingPathComponent(mdPath).path

        let draft = AtelierTask.newDraft(
            id: id,
            projectId: project.id,
            title: trimmed,
            mdPath: mdPath,
            priority: priority,
            workerModel: workerModel ?? project.defaultModel
        )

        try BacklogMD.write(task: draft, to: absolutePath)
        try await db.write { db in
            var copy = draft
            try copy.insert(db)
        }
        return draft
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
