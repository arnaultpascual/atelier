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

    // MARK: - Managed worker (not task-bound)

    /// Outcome of a `runManagedWorker` run — a write-capable worker not tied to a kanban task.
    struct ManagedOutcome: Sendable {
        let completed: Bool
        let costUsd: Double
        let looksUsageLimited: Bool
    }

    /// Runs a write-capable, approval-gated worker in `workingDirectory` on whatever branch is
    /// checked out there — WITHOUT a worktree, Agent row, or task-status side effects. Used by the
    /// feature synthesis pass to fix the integration branch in place (that branch is Atelier's own
    /// isolated `atelier/autopilot-…`, never the user's main/develop). Mirrors `execute`'s approval
    /// wiring (socket + MCP config + rules) in autopilot auto-accept mode.
    func runManagedWorker(label: String,
                          prompt: String,
                          workingDirectory: String,
                          additionalDirs: [String] = [],
                          project: Project,
                          model: String,
                          apiKey: String,
                          store: AppStore,
                          server: ApprovalServer,
                          approvalQueue: ApprovalQueue,
                          maxTurns: Int = 60,
                          featureId: String? = nil) async -> ManagedOutcome {
        let profile = ProjectProfile.find(id: project.profileId) ?? .generic
        let agentId = UUID()
        let session: WorkerSpawnSession
        do {
            session = try await WorkerSpawnSession.begin(
                agentId: agentId, approvalTaskId: "feature-synthesis", project: project,
                rulesWorktreePath: workingDirectory, server: server, approvalQueue: approvalQueue,
                autopilot: true, mcpFeatureId: featureId, mcpTaskId: nil, store: store)
        } catch {
            logger.error("managed worker session failed: \(error.localizedDescription, privacy: .public)")
            return ManagedOutcome(completed: false, costUsd: 0, looksUsageLimited: false)
        }
        var dirs = additionalDirs
        if !dirs.contains(project.path) { dirs.append(project.path) }

        // Teach the synthesis / coverage worker to use its MCP tools (if attached).
        var managedPrompt = prompt
        if let fid = session.mcpFeatureId {
            managedPrompt += "\n\n" + MCPCapability.managedWorkerGuidance(featureId: fid)
        }

        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: managedPrompt, model: model, apiKey: apiKey, agentId: agentId,
            settingsPath: session.settingsPath, workingDirectory: workingDirectory,
            additionalDirs: dirs, includePartialMessages: false, maxTurns: maxTurns,
            resumeSessionId: nil,
            extraEnv: ToolchainChecker.environmentExports(profile: profile, mainRepoPath: project.path),
            mcpConfigPath: session.mcpConfigPath)
        let state = AgentState(); state.reset()
        let liveState = state
        let eventSink: @Sendable (StreamEvent) async -> Void = { event in
            await MainActor.run { liveState.ingest(event) }
        }
        let stderrSink: @Sendable (String) async -> Void = { line in
            await MainActor.run { liveState.appendStderr(line) }
        }
        var ok = true
        do {
            try await runner.run(invocation: invocation, onEvent: eventSink, onStderr: stderrSink)
        } catch {
            ok = false
            if liveState.status != .completed { liveState.markFailed(error.localizedDescription) }
        }
        await session.tearDown(reason: "managed worker finished")
        return ManagedOutcome(completed: ok && liveState.status == .completed,
                              costUsd: liveState.totalCostUsd,
                              looksUsageLimited: liveState.looksUsageLimited)
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
        // 1. Ensure worktree (first ensure a base commit — a freshly-init'd repo has an unborn HEAD).
        let worktree: GitService.WorktreeInfo
        do {
            try await GitService.ensureInitialCommit(projectPath: project.path)
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

        // Resolve the mode once — used for the TDD prompt block and the post-run test gate.
        let profile = ProjectProfile.find(id: project.profileId) ?? .generic

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

        // 4/5. Per-spawn scaffolding: approval socket + settings hook + (optional,
        //      feature-scoped) MCP capability bridge — one object, one teardown.
        let agentId = UUID(uuidString: newAgent.id) ?? UUID()
        let session: WorkerSpawnSession
        do {
            session = try await WorkerSpawnSession.begin(
                agentId: agentId, approvalTaskId: task.id, project: project,
                rulesWorktreePath: worktree.absolutePath, server: server, approvalQueue: approvalQueue,
                autopilot: autopilot, mcpFeatureId: task.featureId, mcpTaskId: task.id, store: store)
        } catch {
            logger.error("worker session setup failed: \(error.localizedDescription, privacy: .public)")
            run.state.markFailed("Could not start worker session: \(error.localizedDescription)")
            finalize(run: run, status: .failed, store: store)
            return
        }

        // 6. Build prompt and additional dirs. When the MCP layer is attached, the
        //    prompt also teaches the worker to use its tools (progress/spec/findings/coverage).
        let prompt = Self.buildPrompt(task: task, project: project, profile: profile, worktree: worktree,
                                      mcpFeatureId: session.mcpFeatureId)
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
            settingsPath: session.settingsPath,
            workingDirectory: worktree.absolutePath,
            additionalDirs: additionalDirs,
            includePartialMessages: false,
            maxTurns: 80,
            resumeSessionId: nil,
            extraEnv: ToolchainChecker.environmentExports(profile: profile, mainRepoPath: project.path),
            mcpConfigPath: session.mcpConfigPath
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

        // 8. Strict-TDD gate, then promote to Review only when green.
        //    The worker is done; now Atelier runs the mode's test command in the
        //    worktree and gates on the exit code. Red → the task stays In Progress
        //    with a summary of why; green (or a mode with no test command) → Review.
        if run.agent.status == .completed {
            if let latest = store.taskByID(task.id), latest.status == .inProgress {
                var gated = latest
                if profile.build.fastTestCommands.isEmpty {
                    gated.testState = .noTests
                    gated.testSummary = nil
                    gated.status = .review
                } else {
                    run.statusHint = "Running tests…"
                    let result = await TestRunner.runFastTests(profile: profile,
                                                               worktreePath: worktree.absolutePath,
                                                               mainRepoPath: project.path)
                    if result.toolchainMissing {
                        // Tooling absent (SDK/JDK/wrapper) — not a code failure. Surface it and let
                        // the task into Review; the tests tab explains what to install.
                        gated.testState = .toolchainMissing
                        gated.testSummary = result.summaryLine
                        gated.status = .review
                    } else {
                        gated.testState = result.passed ? .green : .red
                        gated.testSummary = result.summaryLine
                        // Integrity axis (manual = advisory only, no LLM at the gate): flag whether
                        // the suite was changed/weakened. The deep "was this necessary & still
                        // answers the demand?" review runs on-demand from ReviewSection; it never
                        // blocks the human's merge here.
                        if !profile.build.testDiscoveryGlobs.isEmpty {
                            let signals = await TestIntegrityChecker.inspect(profile: profile,
                                                                             projectPath: project.path,
                                                                             branch: worktree.branch,
                                                                             taskId: task.id)
                            let note = TestIntegrityChecker.declaredNote(worktreePath: worktree.absolutePath, taskId: task.id)
                            gated.testChangeNote = note
                            if !signals.anyTestChange {
                                gated.testIntegrity = .intact
                            } else if !signals.looksWeakened && note != nil {
                                gated.testIntegrity = .evolved
                            } else {
                                gated.testIntegrity = .suspect   // advisory; user can "Review test changes"
                            }
                        }
                        if result.passed { gated.status = .review }
                        // red → stays In Progress; the tests tab / card badge shows why.
                    }
                    run.statusHint = ""
                }
                try? await store.updateTask(gated)
            }
        }

        // 9. Persist final agent state.
        run.agent.endedAt = Date()
        try? await store.updateAgent(run.agent)

        // 10. Tear down the per-spawn scaffolding (socket + settings + MCP).
        await session.tearDown(reason: "worker finished")
        // Drop the transient live-progress badge + block reason now the build phase is over.
        await store.clearProgress(taskId: task.id)
        await store.clearBlockedReason(taskId: task.id)
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
        let session: WorkerSpawnSession
        do {
            session = try await WorkerSpawnSession.begin(
                agentId: agentUUID, approvalTaskId: task.id, project: project,
                rulesWorktreePath: worktreePath, server: server, approvalQueue: approvalQueue,
                autopilot: autopilot, mcpFeatureId: task.featureId, mcpTaskId: task.id, store: store)
        } catch {
            run.state.markFailed("Could not start worker session: \(error.localizedDescription)")
            return
        }

        // Resumed session — if MCP is attached, remind the worker the tools are here.
        var iterateMessage = message
        if let fid = session.mcpFeatureId {
            iterateMessage += "\n\n" + MCPCapability.taskWorkerGuidance(featureId: fid)
        }

        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: iterateMessage,
            model: run.agent.model,
            apiKey: apiKey,
            agentId: agentUUID,
            settingsPath: session.settingsPath,
            workingDirectory: worktreePath,
            additionalDirs: [project.path],
            includePartialMessages: false,
            maxTurns: 40,
            resumeSessionId: sessionId,
            extraEnv: ToolchainChecker.environmentExports(
                profile: ProjectProfile.find(id: project.profileId) ?? .generic,
                mainRepoPath: project.path),
            mcpConfigPath: session.mcpConfigPath
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

        await session.tearDown(reason: "iterate finished")
        await store.clearProgress(taskId: task.id)
        await store.clearBlockedReason(taskId: task.id)
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
                                    profile: ProjectProfile,
                                    worktree: GitService.WorktreeInfo,
                                    mcpFeatureId: String? = nil) -> String {
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

        let b = profile.build
        if !b.fastTestCommands.isEmpty {
            let testCmd = b.fastTestCommands.map(\.command).joined(separator: " && ")
            var tdd = [
                "## Test-driven development (enforced)",
                "This task uses strict TDD. Before writing implementation code:",
                "1. Write the test(s) that specify the desired behavior. Run them; they MUST fail first.",
                "2. Implement until `\(testCmd)` exits 0.",
                "Atelier runs that command in this worktree after you finish; a non-zero exit blocks review/merge until fixed.",
                "",
                "Tests are LIVING, not frozen. If implementation reveals the PLANNED DESIGN was wrong and you change it, the tests you wrote first may assert the old design — you MAY revise or replace them to match the corrected design, as long as the new test asserts the new behavior at EQUAL OR GREATER strength. You may NOT delete, @Ignore/skip, or loosen a test merely to make a real failure go away.",
                "Whenever you change ANY test, declare it: write `.atelier/test-changes/\(task.id).md` with, per change — the test, what changed, and WHY the design changed. Atelier diffs your test files; if the suite shrank or no declaration is found, a reviewer reads that file + the diff to decide legitimate-evolution vs weakening, and unexplained weakening blocks the merge."
            ]
            if let hint = b.testScaffoldingHint { tdd.append(hint) }
            if let target = b.coverageTarget {
                tdd.append("Aim for ≥ \(target)% line coverage on the code you add/change — a SOFT target, not a gate: write tests that meaningfully exercise the new behavior (happy path + edge cases). Being under it never blocks the merge; it only suggests an extra test round.")
            }
            sections.append(tdd.joined(separator: "\n"))
        }

        sections.append("""
        ## House rules

        You're running in a git worktree (`\(worktree.absolutePath)`). The user reviews and merges manually — do not run `git merge`, `git push`, or `git rebase`. Commit liberally on this worktree's branch (`\(worktree.branch)`) so the user can review your diff.
        """)

        // When the MCP capability layer is attached for this feature spawn, teach the
        // worker to actually use its tools (progress, spec-referencing, findings, coverage).
        if let mcpFeatureId {
            sections.append(MCPCapability.taskWorkerGuidance(featureId: mcpFeatureId))
        }

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
