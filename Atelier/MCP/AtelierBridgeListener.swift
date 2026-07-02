// SPDX-License-Identifier: MIT
import Darwin.POSIX
import Foundation
import os

/// Per-spawn Unix-socket listener for the MCP capability bridge — the mirror of
/// `ApprovalSocketListener`, but for capability ops instead of approvals. The
/// embedded `AtelierMCPServer` connects here and round-trips `BridgeRequest` /
/// `BridgeResponse` (newline-delimited JSON). Every mutation is marshalled onto
/// @MainActor through `AppStore`, keeping the app the single GRDB writer.
///
/// Capability only — this never participates in the permission/approval flow.
///
/// Ops (Phase 1):
///   task_report_progress → ephemeral in-memory progress (live kanban %)
///   resource_read        → the living brief.md for the scoped feature
actor AtelierBridgeListener {
    private static let logger = Logger(subsystem: "app.atelier", category: "mcp-bridge")

    let agentId: String
    let featureId: String
    let projectPath: String
    private weak var store: AppStore?

    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private(set) var socketPath: String?

    init(agentId: String, featureId: String, projectPath: String, store: AppStore) {
        self.agentId = agentId
        self.featureId = featureId
        self.projectPath = projectPath
        self.store = store
    }

    func start() throws -> String {
        let shortId = String(agentId.prefix(8))
        let path = "/tmp/at-mcp-\(shortId).sock"   // sun_path is 104 bytes — keep it short
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXErrno("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd); throw POSIXErrno("socket path too long (\(pathBytes.count) bytes)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
                cPtr[pathBytes.count] = 0
            }
        }
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else { Darwin.close(fd); throw POSIXErrno("bind() failed at \(path)") }
        guard listen(fd, 1) == 0 else { Darwin.close(fd); throw POSIXErrno("listen() failed") }

        self.serverFD = fd
        self.socketPath = path
        Self.logger.info("mcp bridge listening at \(path, privacy: .public)")
        self.acceptTask = Task { [weak self] in await self?.acceptLoop() }
        return path
    }

    func stop(reason: String = "worker exited") async {
        acceptTask?.cancel()
        if clientFD >= 0 { close(clientFD); clientFD = -1 }
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        if let p = socketPath { unlink(p); socketPath = nil }
        Self.logger.info("mcp bridge stopped: \(reason, privacy: .public)")
    }

    private func acceptLoop() async {
        let fd = serverFD
        while !Task.isCancelled, fd >= 0 {
            let cfd = await Task.detached { Darwin.accept(fd, nil, nil) }.value
            if Task.isCancelled || cfd < 0 { break }
            self.clientFD = cfd
            await readLoop(clientFD: cfd)
        }
    }

    private func readLoop(clientFD: Int32) async {
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = await Task.detached { () -> Data? in
                var raw = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(clientFD, &raw, raw.count)
                if n <= 0 { return nil }
                return Data(raw[0..<n])
            }.value
            guard let chunk else { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                await handleLine(line, clientFD: clientFD)
            }
        }
    }

    private func handleLine(_ line: Data, clientFD: Int32) async {
        guard let request = try? MCPCodec.decoder.decode(BridgeRequest.self, from: line) else {
            Self.logger.warning("malformed bridge request")
            return
        }
        let response = await handle(request)
        respond(clientFD: clientFD, response: response)
    }

    private func respond(clientFD: Int32, response: BridgeResponse) {
        guard var data = try? MCPCodec.encoder.encode(response) else { return }
        data.append(0x0A)
        var rest = data
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { Darwin.write(clientFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            rest.removeFirst(n)
        }
    }

    // MARK: - Op routing (all app state touched on @MainActor)

    private func handle(_ req: BridgeRequest) async -> BridgeResponse {
        guard let store = self.store else {
            return .failure(id: req.id, error: "app store unavailable")
        }
        let featureId = self.featureId
        switch req.op {
        case "task_report_progress":
            guard let taskId = req.taskId, !taskId.isEmpty else {
                return .failure(id: req.id, error: "missing taskId")
            }
            let pct = req.args["pct"]?.intValue ?? 0
            let note = req.args["note"]?.stringValue
            await MainActor.run { store.reportProgress(taskId: taskId, pct: pct, note: note) }
            return .success(id: req.id, result: nil)

        case "resource_read":
            // Resolve the living-brief URL on @MainActor (store access only), then
            // read the file OFF the main actor (no blocking I/O on MainActor).
            let (featureFound, url): (Bool, URL?) = await MainActor.run {
                guard let feature = store.featureByID(featureId) else { return (false, nil) }
                return (true, feature.briefRoomId.flatMap { store.chatRoom(id: $0) }?.briefFileURL)
            }
            switch Self.briefResolution(featureFound: featureFound, briefURL: url) {
            case .notFound(let err):
                return .failure(id: req.id, error: err)
            case .empty:
                return .success(id: req.id, result: Self.markdownResource(""))
            case .url(let fileURL):
                return .success(id: req.id, result: Self.markdownResource(Self.readBriefFile(fileURL)))
            }

        case let op where op.hasPrefix("brief_") || op == "spec_record_finding":
            return await handleBriefMutation(op, req, store: store)

        case "task_update_status":
            return await handleUpdateStatus(req, store: store)
        case "task_signal_blocked":
            return await handleSignalBlocked(req, store: store)
        case "task_get_dependencies":
            return await handleGetDependencies(req, store: store)
        case "plan_next_wave":
            return await handlePlanNextWave(req, store: store)
        case "test_report_run":
            return await handleTestReportRun(req, store: store)
        case "review_request":
            return await handleReviewRequest(req, store: store)
        case "coverage_get":
            return await handleCoverage(req, store: store, uncoveredOnly: false)
        case "coverage_uncovered":
            return await handleCoverage(req, store: store, uncoveredOnly: true)

        default:
            return .failure(id: req.id, error: "unknown op: \(req.op)")
        }
    }

    private func msg(_ s: String) -> JSONValue { .object(["message": .string(s)]) }
    private func txt(_ s: String) -> JSONValue { .object(["text": .string(s)]) }

    // MARK: brief building (Phase 2)

    private func handleBriefMutation(_ op: String, _ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        let featureId = self.featureId
        let resolved: (url: URL, roomId: String)? = await MainActor.run {
            guard let feature = store.featureByID(featureId),
                  let roomId = feature.briefRoomId,
                  let room = store.chatRoom(id: roomId) else { return nil }
            return (room.briefFileURL, roomId)
        }
        guard let (url, roomId) = resolved else {
            return .failure(id: req.id, error: "no brief document for feature \(featureId)")
        }
        var doc = BriefDocument.parse(Self.readBriefFile(url))
        guard let message = Self.applyBriefOp(op, args: req.args, to: &doc) else {
            return .failure(id: req.id, error: "invalid arguments for \(op)")
        }
        do {
            try doc.rendered().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .failure(id: req.id, error: "could not write brief: \(error.localizedDescription)")
        }
        await MainActor.run { store.bumpBriefRevision(roomId: roomId) }
        return .success(id: req.id, result: msg(message))
    }

    /// Pure brief-op dispatcher (unit-tested). Returns an ack message, or nil on
    /// bad args / unknown op / a resolve that found nothing.
    static func applyBriefOp(_ op: String, args: JSONValue, to doc: inout BriefDocument) -> String? {
        // Required text args must be non-blank; optional ones pass through as-is.
        func req(_ key: String) -> String? {
            guard let s = args[key]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        switch op {
        case "brief_set_overview":
            guard let md = req("markdown") else { return nil }
            doc.setOverview(md); return "Overview updated."
        case "brief_append_section":
            guard let h = req("heading"), let md = req("markdown") else { return nil }
            doc.appendSection(heading: h, markdown: md); return "Section “\(h)” appended."
        case "brief_add_requirement":
            guard let t = req("text") else { return nil }
            doc.addRequirement(t, priority: args["priority"]?.stringValue); return "Requirement added."
        case "brief_add_acceptance_criterion":
            guard let t = req("text") else { return nil }
            doc.addAcceptanceCriterion(t); return "Acceptance criterion added."
        case "brief_add_open_question":
            guard let t = req("text") else { return nil }
            doc.addOpenQuestion(t); return "Open question recorded."
        case "brief_resolve_open_question":
            guard let idx = args["index"]?.intValue, let a = req("answer") else { return nil }
            return doc.resolveOpenQuestion(index: idx, answer: a) ? "Open question \(idx) resolved." : nil
        case "brief_record_decision":
            guard let d = req("decision"), let r = req("rationale") else { return nil }
            doc.recordDecision(d, rationale: r); return "Decision recorded."
        case "brief_attach_reference":
            guard let u = req("urlOrPath") else { return nil }
            doc.attachReference(u, note: args["note"]?.stringValue); return "Reference attached."
        case "spec_record_finding":
            guard let f = req("finding") else { return nil }
            doc.recordFinding(f, impact: args["impact"]?.stringValue, workaround: args["workaround"]?.stringValue)
            return "Finding recorded in the spec."
        default:
            return nil
        }
    }

    // MARK: tasks / waves (Phase 3)

    private func handleUpdateStatus(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        guard let taskId = req.taskId, !taskId.isEmpty else { return .failure(id: req.id, error: "missing taskId") }
        guard let statusStr = req.args["status"]?.stringValue,
              let status = AtelierTask.Status(rawValue: statusStr) else {
            return .failure(id: req.id, error: "invalid status (use: \(AtelierTask.Status.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        // `.done` is a MERGE outcome owned by the app — a worker can't self-declare it.
        guard status != .done else {
            return .failure(id: req.id, error: "cannot set Done via MCP — Done follows a successful merge. Use Review when ready.")
        }
        // fresh-read-then-write to avoid clobbering concurrently-set fields (testState etc.)
        guard var task = await store.freshTask(taskId) else { return .failure(id: req.id, error: "task \(taskId) not found") }
        task.status = status
        do { try await store.updateTask(task) } catch { return .failure(id: req.id, error: error.localizedDescription) }
        if status != .blocked { await MainActor.run { store.clearBlockedReason(taskId: taskId) } }
        return .success(id: req.id, result: msg("Task \(taskId) → \(status.rawValue)."))
    }

    private func handleSignalBlocked(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        guard let taskId = req.taskId, !taskId.isEmpty else { return .failure(id: req.id, error: "missing taskId") }
        guard let reason = req.args["reason"]?.stringValue else { return .failure(id: req.id, error: "missing reason") }
        guard var task = await store.freshTask(taskId) else { return .failure(id: req.id, error: "task \(taskId) not found") }
        task.status = .blocked
        do { try await store.updateTask(task) } catch { return .failure(id: req.id, error: error.localizedDescription) }
        let needs = req.args["needs"]?.stringValue.map { " Needs: \($0)" } ?? ""
        await MainActor.run { store.setBlockedReason(taskId: taskId, reason: reason + needs) }
        return .success(id: req.id, result: msg("Task \(taskId) moved to Blocked; reason recorded on the card."))
    }

    private func handleGetDependencies(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        guard let taskId = req.taskId, !taskId.isEmpty else { return .failure(id: req.id, error: "missing taskId") }
        guard let task = await store.freshTask(taskId) else { return .failure(id: req.id, error: "task \(taskId) not found") }
        if task.dependsOn.isEmpty { return .success(id: req.id, result: txt("No dependencies — runnable now.")) }
        var lines: [String] = []
        var allDone = true
        for depId in task.dependsOn {
            let dep = await store.freshTask(depId)   // committed row, not the lagging cache
            let status = dep?.status.rawValue ?? "unknown"
            if dep?.status != .done { allDone = false }
            lines.append("- \(depId): \(status)\(dep == nil ? " (not found)" : "")")
        }
        let verdict = allDone ? "Runnable now (all dependencies done)." : "Blocked by unfinished dependencies."
        return .success(id: req.id, result: txt("Dependencies of \(taskId):\n\(lines.joined(separator: "\n"))\n\(verdict)"))
    }

    private func handlePlanNextWave(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        let featureId = self.featureId
        let (runnable, remaining): ([String], Int) = await MainActor.run {
            guard let feature = store.featureByID(featureId) else { return ([], 0) }
            let allProjectTasks = store.tasks(in: feature.projectId)   // cross-scope deps must block
            let featureTasks = store.tasks(inFeature: featureId)
            let todo = featureTasks.filter { $0.status == .toDo }
            let now = ExecutionPlanner.runnableNow(tasks: todo, allTasks: allProjectTasks)
            return (now.map { "\($0.id): \($0.title)" }, todo.count)
        }
        if runnable.isEmpty {
            return .success(id: req.id, result: txt(remaining == 0 ? "No To Do tasks remain." : "No tasks runnable yet — all remaining To Do tasks are blocked by dependencies."))
        }
        return .success(id: req.id, result: txt("Runnable now (\(runnable.count) of \(remaining) To Do):\n" + runnable.map { "- \($0)" }.joined(separator: "\n")))
    }

    private func handleTestReportRun(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        guard let taskId = req.taskId, !taskId.isEmpty else { return .failure(id: req.id, error: "missing taskId") }
        guard let passed = req.args["passed"]?.intValue, let failed = req.args["failed"]?.intValue else {
            return .failure(id: req.id, error: "passed and failed are required integers")
        }
        let skipped = req.args["skipped"]?.intValue
        let coveragePct = req.args["coveragePct"]?.intValue
        guard var task = await store.freshTask(taskId) else { return .failure(id: req.id, error: "task \(taskId) not found") }
        // INFORMATIONAL ONLY. We deliberately do NOT write `testState` — that is the
        // deterministic, Atelier-run merge gate (see TaskSpawner's post-run gate). A
        // worker's self-reported counts must never be able to flip the gate green.
        var summary = "worker-reported: \(passed) passed / \(failed) failed"
        if let skipped { summary += " / \(skipped) skipped" }
        if let coveragePct { summary += " · coverage \(coveragePct)%" }
        task.testSummary = summary
        do { try await store.updateTask(task) } catch { return .failure(id: req.id, error: error.localizedDescription) }
        return .success(id: req.id, result: msg("Recorded (advisory): \(summary). The merge gate still runs the tests itself."))
    }

    private func handleReviewRequest(_ req: BridgeRequest, store: AppStore) async -> BridgeResponse {
        guard let taskId = req.taskId, !taskId.isEmpty else { return .failure(id: req.id, error: "missing taskId") }
        guard let task = await store.freshTask(taskId) else { return .failure(id: req.id, error: "task \(taskId) not found") }
        // Run the SAME Opus reviewer the autopilot uses, against the task's worktree.
        // This is a long call (spawns a review worker) — the tool blocks until it returns.
        guard let worktree = (try? await store.agentsForTask(taskId))?.first?.worktreePath, !worktree.isEmpty else {
            return .failure(id: req.id, error: "no worktree for task \(taskId) yet — nothing to review")
        }
        let fid = self.featureId
        let base = await MainActor.run { store.featureByID(fid)?.integrationBranch } ?? "main"
        let key = await MainActor.run { APIKeyResolver.resolve() }
        do {
            let report = try await AIAssistant.reviewWorktree(
                taskTitle: task.title,
                taskDescription: task.descriptionMd ?? "",
                worktreePath: worktree,
                baseBranch: base,
                apiKey: key.isEmpty ? nil : key)
            let findings = report.findings.isEmpty ? "No findings."
                : report.findings.map { "• \($0.oneLine)" }.joined(separator: "\n")
            return .success(id: req.id, result: msg("Review [\(report.verdict.rawValue)] — \(report.summary)\n\(findings)"))
        } catch {
            return .failure(id: req.id, error: "review failed: \(error.localizedDescription)")
        }
    }

    // MARK: coverage (Phase 3, D3 multi-mode)

    private func handleCoverage(_ req: BridgeRequest, store: AppStore, uncoveredOnly: Bool) async -> BridgeResponse {
        let featureId = self.featureId
        let taskId = req.taskId
        // Resolve where coverage lives + the soft target, on @MainActor.
        let base: (projectPath: String, target: Int, mode: String)? = await MainActor.run {
            guard let feature = store.featureByID(featureId),
                  let project = store.projectByID(feature.projectId) else { return nil }
            let profile = ProjectProfile.find(id: project.profileId) ?? .generic
            let target = profile.build.coverageTarget ?? 90   // soft 90% aim for every mode (D3)
            return (project.path, target, profile.id)
        }
        guard let base else { return .failure(id: req.id, error: "could not resolve feature/project for coverage") }
        // Prefer the calling task's worktree (where the worker ran tests); else project root.
        var worktree = base.projectPath
        if let taskId, let agents = try? await store.agentsForTask(taskId),
           let wt = agents.first?.worktreePath, !wt.isEmpty {
            worktree = wt
        }
        guard let report = CoverageReport.find(in: worktree) else {
            return .success(id: req.id, result: txt("No coverage report found in the worktree yet. Run your tests with coverage enabled (e.g. swift test --enable-code-coverage, c8/nyc, or `coverage xml`) then retry."))
        }
        if uncoveredOnly {
            let below = report.belowTarget(base.target)
            if below.isEmpty { return .success(id: req.id, result: txt("All files meet the \(base.target)% target (overall \(report.percent)%).")) }
            let lines = below.prefix(25).map { "- \($0.path): \(Int(($0.rate * 100).rounded()))%" }
            return .success(id: req.id, result: txt("Below \(base.target)% (overall \(report.percent)%):\n" + lines.joined(separator: "\n")))
        } else {
            let gap = max(0, base.target - report.percent)
            return .success(id: req.id, result: txt("Coverage \(report.percent)% vs target \(base.target)% (gap \(gap)) [\(base.mode)]."))
        }
    }

    /// Pure decision for a living-brief resource read (unit-tested):
    /// - feature absent → error; feature present but no brief room yet → empty
    ///   (brief stage not entered); otherwise read the resolved URL.
    enum BriefResolution: Equatable, Sendable { case url(URL); case empty; case notFound(String) }

    static func briefResolution(featureFound: Bool, briefURL: URL?) -> BriefResolution {
        guard featureFound else { return .notFound("feature not found") }
        guard let briefURL else { return .empty }   // brief stage not entered yet
        return .url(briefURL)
    }

    /// Reads a brief file, tolerating a not-yet-created file (→ empty string).
    static func readBriefFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func markdownResource(_ text: String) -> JSONValue {
        .object(["text": .string(text), "mimeType": .string("text/markdown")])
    }
}
