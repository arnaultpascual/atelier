// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Owns the lifecycle of task-bound workers: one spawn = one git worktree + one
/// claude subprocess + one persisted Agent row + one in-memory AgentState that
/// the inspector observes live.
///
/// `runs[task.id]` is the currently active or just-finished run for a task; it stays
/// around so the inspector can show "Completed — $0.42 · 12s" until the user starts
/// another spawn, closes the inspector, or selects another task.
@MainActor
@Observable
final class TaskSpawner {
    private(set) var runs: [String: ActiveRun] = [:]
    private let logger = Logger(subsystem: "app.atelier", category: "spawner")

    func activeRun(for taskId: String) -> ActiveRun? {
        runs[taskId]
    }

    /// Returns true if the task has a run in a non-terminal state.
    func hasLiveWorker(for taskId: String) -> Bool {
        guard let run = runs[taskId] else { return false }
        return !run.agent.status.isTerminal
    }

    /// Drop the cached run (used when user dismisses the agent view to go back to
    /// task editing). The worker itself is left running if still alive — call
    /// `cancel(taskId:)` first if you actually want to stop it.
    func dismiss(taskId: String) {
        runs[taskId] = nil
    }

    /// Sends task cancellation to the worker. The subprocess receives SIGTERM via
    /// swift-subprocess's cooperative cancellation.
    func cancel(taskId: String) {
        guard let run = runs[taskId] else { return }
        run.workerTask?.cancel()
        run.state.markFailed("Cancelled by user")
        run.agent.status = .killed
        run.agent.endedAt = Date()
    }

    /// Starts a new run for the task. Replaces any prior run for that task (the
    /// prior one is dropped from the in-memory dict — its DB row stays).
    func start(task: AtelierTask,
               project: Project,
               apiKey: String,
               store: AppStore,
               server: ApprovalServer,
               approvalQueue: ApprovalQueue) {
        // If there's already a live worker, no-op (the UI should disable the button
        // in that case).
        if hasLiveWorker(for: task.id) { return }

        let model = ModelRouter.resolve(task: task, projectDefault: project.defaultModel)
        let run = ActiveRun(taskId: task.id, model: model)
        run.statusHint = "Preparing worktree…"
        runs[task.id] = run

        run.workerTask = Task { @MainActor in
            await self.execute(task: task,
                               project: project,
                               apiKey: apiKey,
                               model: model,
                               run: run,
                               store: store,
                               server: server,
                               approvalQueue: approvalQueue)
        }
    }

    // MARK: - Autopilot (awaitable)

    /// Like `start`, but awaits the worker to completion and returns the finished run (so the
    /// caller can read status / sessionId / cost). The work still runs in a cancellable
    /// `run.workerTask`, so `cancel(taskId:)` stops it. `autopilot:true` makes the approval queue
    /// auto-accept anything not explicitly denied.
    @discardableResult
    func spawnAndAwait(task: AtelierTask,
                       project: Project,
                       apiKey: String,
                       store: AppStore,
                       server: ApprovalServer,
                       approvalQueue: ApprovalQueue,
                       autopilot: Bool = false) async -> ActiveRun? {
        if hasLiveWorker(for: task.id) { return runs[task.id] }
        let model = ModelRouter.resolve(task: task, projectDefault: project.defaultModel)
        let run = ActiveRun(taskId: task.id, model: model)
        run.statusHint = "Preparing worktree…"
        runs[task.id] = run
        let work = Task { @MainActor in
            await self.execute(task: task, project: project, apiKey: apiKey, model: model,
                               run: run, store: store, server: server,
                               approvalQueue: approvalQueue, autopilot: autopilot)
        }
        run.workerTask = work
        await work.value
        return run
    }

    /// Awaitable variant of `iterate` for the autopilot's fix passes: resumes the prior session
    /// with `message`, awaits completion, returns the run. Returns nil if the prior agent has no
    /// resumable session or its worktree is gone.
    @discardableResult
    func iterateAndAwait(task: AtelierTask,
                         project: Project,
                         priorAgent: Agent,
                         message: String,
                         apiKey: String,
                         store: AppStore,
                         server: ApprovalServer,
                         approvalQueue: ApprovalQueue,
                         autopilot: Bool = false) async -> ActiveRun? {
        guard !hasLiveWorker(for: task.id) else { return runs[task.id] }
        guard let sessionId = priorAgent.sessionId, !sessionId.isEmpty else { return nil }
        let worktreePath = priorAgent.worktreePath
        guard !worktreePath.isEmpty,
              FileManager.default.fileExists(atPath: worktreePath) else { return nil }
        let run = ActiveRun(taskId: task.id, model: priorAgent.model)
        run.statusHint = "Resuming session…"
        run.agent = priorAgent
        run.agent.endedAt = nil
        run.agent.status = .running
        run.state.totalCostUsd = priorAgent.costUsd
        run.state.inputTokens = priorAgent.inputTokens
        run.state.outputTokens = priorAgent.outputTokens
        run.state.cacheReadTokens = priorAgent.cacheReadTokens
        run.state.cacheCreationTokens = priorAgent.cacheCreationTokens
        runs[task.id] = run
        let work = Task { @MainActor in
            await self.executeIterate(task: task, project: project, run: run, sessionId: sessionId,
                                      worktreePath: worktreePath, message: message, apiKey: apiKey,
                                      store: store, server: server, approvalQueue: approvalQueue,
                                      autopilot: autopilot)
        }
        run.workerTask = work
        await work.value
        return run
    }

    // MARK: - Internals

    private func execute(task: AtelierTask,
                         project: Project,
                         apiKey: String,
                         model: String,
                         run: ActiveRun,
                         store: AppStore,
                         server: ApprovalServer,
                         approvalQueue: ApprovalQueue,
                         autopilot: Bool = false) async {
        // 1. Ensure worktree
        let worktree: GitService.WorktreeInfo
        do {
            worktree = try await GitService.ensureWorktree(projectPath: project.path,
                                                           taskId: task.id)
        } catch {
            run.statusHint = ""
            run.state.markFailed(error.localizedDescription)
            run.agent.status = .failed
            run.agent.endedAt = Date()
            logger.error("worktree setup failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        run.agent.worktreePath = worktree.absolutePath
        run.agent.branch = worktree.branch

        // Drop bundled Skills (universal + the project's matched profile) into
        // <worktree>/.claude/skills/ so the worker picks them up automatically.
        let skillReport = SkillBundler.installSkills(worktreePath: worktree.absolutePath,
                                                     profileId: project.profileId)
        if !skillReport.errors.isEmpty {
            logger.warning("skill install issues: \(skillReport.errors.joined(separator: "; "), privacy: .public)")
        }

        // 2. Insert Agent row (snapshot the spawn). Update on the fly afterwards.
        var newAgent = Agent.newSpawn(taskId: task.id,
                                      worktreePath: worktree.absolutePath,
                                      branch: worktree.branch,
                                      model: model)
        run.agent = newAgent
        try? await store.insertAgent(newAgent)

        // 3. Set task status → In Progress (if it was To Do/Review/Blocked)
        if task.status != .inProgress && task.status != .done {
            try? await store.updateTaskStatus(task, to: .inProgress)
        }

        // 4. Start the per-spawn approval socket listener and write the MCP config
        //    that points the helper at it.
        let agentId = UUID(uuidString: newAgent.id) ?? UUID()
        let listener = ApprovalSocketListener(
            agentId: agentId.uuidString,
            taskId: task.id,
            projectName: project.name,
            queue: approvalQueue
        )
        let socketPath: String
        do {
            socketPath = try await listener.start()
            logger.info("approval socket: \(socketPath, privacy: .public)")
        } catch {
            logger.error("approval socket start failed: \(error.localizedDescription, privacy: .public)")
            run.state.markFailed("Could not open approval socket: \(error.localizedDescription)")
            finalize(run: run, status: .failed, store: store)
            return
        }
        // Load profile + per-project permission rules into the queue so any
        // approval the helper enqueues gets evaluated against them.
        approvalQueue.loadRules(forAgent: agentId.uuidString,
                                project: project,
                                worktreePath: worktree.absolutePath)
        if autopilot { approvalQueue.setAutopilot(true, forAgent: agentId.uuidString) }
        let configURL: URL
        do {
            configURL = try MCPConfig.writeTemporaryConfig(
                serverName: server.serverName,
                agentId: agentId,
                socketPath: socketPath
            )
        } catch {
            logger.error("MCP config write failed: \(error.localizedDescription, privacy: .public)")
            await listener.stop(reason: "config write failed")
            run.state.markFailed("Could not write MCP config: \(error.localizedDescription)")
            finalize(run: run, status: .failed, store: store)
            return
        }

        // 6. Build prompt and additional dirs
        let prompt = Self.buildPrompt(task: task, project: project, worktree: worktree)
        let attachmentsDir = URL(fileURLWithPath: project.path)
            .appendingPathComponent(".atelier")
            .appendingPathComponent("attachments")
            .appendingPathComponent(task.id)
            .path
        var additionalDirs: [String] = []
        if FileManager.default.fileExists(atPath: attachmentsDir) {
            additionalDirs.append(attachmentsDir)
        }
        // Give worker access to the project root so it can read backlog/, ., etc.
        additionalDirs.append(project.path)

        // 7. Launch worker
        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: prompt,
            model: model,
            apiKey: apiKey,
            agentId: agentId,
            settingsPath: configURL.path,
            workingDirectory: worktree.absolutePath,
            additionalDirs: additionalDirs,
            includePartialMessages: false,
            maxTurns: 80,
            resumeSessionId: nil
        )

        run.statusHint = ""
        run.agent.status = .running
        newAgent.status = .running
        try? await store.updateAgent(newAgent)

        let liveState = run.state
        let liveAgent = run
        let budgetCap = task.budgetUsd

        let eventSink: @Sendable (StreamEvent) async -> Void = { event in
            await MainActor.run {
                liveState.ingest(event)
                Self.absorbStreamEventIntoAgent(event, run: liveAgent)
                Self.enforceBudget(state: liveState,
                                   run: liveAgent,
                                   cap: budgetCap)
            }
        }
        let stderrSink: @Sendable (String) async -> Void = { line in
            await MainActor.run {
                liveState.appendStderr(line)
            }
        }

        var finalStatus: Agent.Status = .completed
        do {
            try await runner.run(invocation: invocation,
                                 onEvent: eventSink,
                                 onStderr: stderrSink)
        } catch {
            if Task.isCancelled {
                finalStatus = .killed
            } else {
                finalStatus = .failed
                if liveState.status != .completed {
                    liveState.markFailed(error.localizedDescription)
                }
            }
        }

        // If the stream's `result` event hadn't set the agent status yet, derive it.
        if !run.agent.status.isTerminal {
            run.agent.status = finalStatus
        }

        // 8. Promote task to Review on success.
        if run.agent.status == .completed {
            if let latest = store.taskByID(task.id), latest.status == .inProgress {
                try? await store.updateTaskStatus(latest, to: .review)
            }
        }

        // 9. Persist final agent state.
        run.agent.endedAt = Date()
        try? await store.updateAgent(run.agent)

        // 10. Cleanup temp config + socket
        MCPConfig.cleanup(configURL)
        await listener.stop(reason: "worker finished")
    }

    /// Re-spawns a worker that `--resume`s a prior claude session for the given
    /// task, with `message` as the new user turn. Used by IterateView.
    /// Requires the prior agent to have a non-nil sessionId and a worktree that
    /// still exists on disk.
    func iterate(task: AtelierTask,
                 project: Project,
                 priorAgent: Agent,
                 message: String,
                 apiKey: String,
                 store: AppStore,
                 server: ApprovalServer,
                 approvalQueue: ApprovalQueue) {
        guard !hasLiveWorker(for: task.id) else { return }
        guard let sessionId = priorAgent.sessionId, !sessionId.isEmpty else { return }
        let worktreePath = priorAgent.worktreePath
        guard !worktreePath.isEmpty,
              FileManager.default.fileExists(atPath: worktreePath) else {
            return
        }

        let model = priorAgent.model
        let run = ActiveRun(taskId: task.id, model: model)
        run.statusHint = "Resuming session…"
        run.agent = priorAgent
        run.agent.endedAt = nil
        run.agent.status = .running
        // Seed the live state with what the prior session accumulated so
        // result events from this turn add on top rather than starting from 0.
        run.state.totalCostUsd = priorAgent.costUsd
        run.state.inputTokens = priorAgent.inputTokens
        run.state.outputTokens = priorAgent.outputTokens
        run.state.cacheReadTokens = priorAgent.cacheReadTokens
        run.state.cacheCreationTokens = priorAgent.cacheCreationTokens
        runs[task.id] = run

        run.workerTask = Task { @MainActor in
            await self.executeIterate(task: task,
                                      project: project,
                                      run: run,
                                      sessionId: sessionId,
                                      worktreePath: worktreePath,
                                      message: message,
                                      apiKey: apiKey,
                                      store: store,
                                      server: server,
                                      approvalQueue: approvalQueue)
        }
    }

    private func executeIterate(task: AtelierTask,
                                project: Project,
                                run: ActiveRun,
                                sessionId: String,
                                worktreePath: String,
                                message: String,
                                apiKey: String,
                                store: AppStore,
                                server: ApprovalServer,
                                approvalQueue: ApprovalQueue,
                                autopilot: Bool = false) async {
        let agentUUID = UUID(uuidString: run.agent.id) ?? UUID()
        let listener = ApprovalSocketListener(
            agentId: agentUUID.uuidString,
            taskId: task.id,
            projectName: project.name,
            queue: approvalQueue
        )
        let socketPath: String
        do {
            socketPath = try await listener.start()
        } catch {
            run.state.markFailed("Could not open approval socket: \(error.localizedDescription)")
            return
        }
        approvalQueue.loadRules(forAgent: agentUUID.uuidString,
                                project: project,
                                worktreePath: worktreePath)
        if autopilot { approvalQueue.setAutopilot(true, forAgent: agentUUID.uuidString) }
        let configURL: URL
        do {
            configURL = try MCPConfig.writeTemporaryConfig(
                serverName: server.serverName,
                agentId: agentUUID,
                socketPath: socketPath
            )
        } catch {
            await listener.stop(reason: "config write failed")
            run.state.markFailed("Could not write MCP config: \(error.localizedDescription)")
            return
        }

        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: message,
            model: run.agent.model,
            apiKey: apiKey,
            agentId: agentUUID,
            settingsPath: configURL.path,
            workingDirectory: worktreePath,
            additionalDirs: [project.path],
            includePartialMessages: false,
            maxTurns: 40,
            resumeSessionId: sessionId
        )

        run.statusHint = ""
        let liveState = run.state
        let liveRun = run
        let iterateBudget = task.budgetUsd
        let eventSink: @Sendable (StreamEvent) async -> Void = { event in
            await MainActor.run {
                liveState.ingest(event)
                Self.absorbStreamEventIntoAgent(event, run: liveRun)
                Self.enforceBudget(state: liveState,
                                   run: liveRun,
                                   cap: iterateBudget)
            }
        }
        let stderrSink: @Sendable (String) async -> Void = { line in
            await MainActor.run { liveState.appendStderr(line) }
        }

        var finalStatus: Agent.Status = .completed
        do {
            try await runner.run(invocation: invocation,
                                 onEvent: eventSink,
                                 onStderr: stderrSink)
        } catch {
            if Task.isCancelled {
                finalStatus = .killed
            } else {
                finalStatus = .failed
                if liveState.status != .completed {
                    liveState.markFailed(error.localizedDescription)
                }
            }
        }

        if !run.agent.status.isTerminal {
            run.agent.status = finalStatus
        }
        run.agent.endedAt = Date()
        try? await store.updateAgent(run.agent)

        MCPConfig.cleanup(configURL)
        await listener.stop(reason: "iterate finished")
    }

    private func finalize(run: ActiveRun, status: Agent.Status, store: AppStore) {
        run.agent.status = status
        run.agent.endedAt = Date()
        Task { try? await store.updateAgent(run.agent) }
    }

    /// Cancels the worker if the running cost has crossed the task's
    /// configured cap. Idempotent — once cancelled, statusHint flags the
    /// reason and we don't try to cancel again.
    private static func enforceBudget(state: AgentState,
                                      run: ActiveRun,
                                      cap: Double?) {
        guard let cap, cap > 0 else { return }
        guard state.totalCostUsd >= cap else { return }
        guard run.workerTask?.isCancelled == false else { return }
        let msg = String(format: "Budget cap exceeded — $%.4f spent of $%.2f. Worker auto-aborted.",
                         state.totalCostUsd, cap)
        state.lastErrorMessage = msg
        run.statusHint = "Aborted: budget cap reached"
        run.workerTask?.cancel()
    }

    /// Translates stream-json events into agent record updates (cost, tokens, sessionId).
    private static func absorbStreamEventIntoAgent(_ event: StreamEvent, run: ActiveRun) {
        switch event.kind {
        case .system(_, let sessionId, _):
            if let s = sessionId, run.agent.sessionId == nil {
                run.agent.sessionId = s
            }
        case .result(_, let cost, let usage, let isError):
            if let c = cost { run.agent.costUsd += c }
            if let u = usage {
                run.agent.inputTokens += u.inputTokens
                run.agent.outputTokens += u.outputTokens
                run.agent.cacheReadTokens += u.cacheReadTokens
                run.agent.cacheCreationTokens += u.cacheCreationTokens
            }
            run.agent.status = isError ? .failed : .completed
        default:
            break
        }
    }

    // MARK: - Prompt building

    private static func buildPrompt(task: AtelierTask,
                                    project: Project,
                                    worktree: GitService.WorktreeInfo) -> String {
        var sections: [String] = []
        sections.append("# \(task.title)")

        var meta: [String] = []
        meta.append("Task id: `\(task.id)`")
        meta.append("Branch: `\(worktree.branch)` (worktree under `\(worktree.relativePath)`)")
        meta.append("Project root: `\(project.path)`")
        if !task.labels.isEmpty {
            meta.append("Labels: \(task.labels.joined(separator: ", "))")
        }
        if let p = task.priority {
            meta.append("Priority: \(p.displayName)")
        }
        sections.append(meta.joined(separator: "  \n"))

        if let body = task.descriptionMd?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            sections.append(body)
        }

        if !task.attachments.isEmpty {
            var att = ["## Attachments\n",
                       "The user attached these files to the task. Read them when needed:"]
            for rel in task.attachments {
                let abs = URL(fileURLWithPath: project.path).appendingPathComponent(rel).path
                att.append("- `\(abs)`")
            }
            sections.append(att.joined(separator: "\n"))
        }

        sections.append("""
        ## House rules

        You're running in a git worktree (`\(worktree.absolutePath)`). The user reviews and merges manually — do not run `git merge`, `git push`, or `git rebase`. Commit liberally on this worktree's branch (`\(worktree.branch)`) so the user can review your diff.
        """)

        return sections.joined(separator: "\n\n")
    }
}

// MARK: - ActiveRun

@MainActor
@Observable
final class ActiveRun {
    let taskId: String
    var agent: Agent
    var state: AgentState
    var workerTask: Task<Void, Never>?
    var statusHint: String

    init(taskId: String, model: String) {
        self.taskId = taskId
        self.agent = Agent(
            id: UUID().uuidString,
            taskId: taskId,
            worktreePath: "",
            branch: "",
            pid: nil,
            status: .spawned,
            model: model,
            sessionId: nil,
            sessionJsonlPath: nil,
            costUsd: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            startedAt: Date(),
            endedAt: nil
        )
        self.state = AgentState()
        self.statusHint = ""
        // Safe to mutate `state` now that all stored properties are initialised.
        self.state.reset()
    }
}
