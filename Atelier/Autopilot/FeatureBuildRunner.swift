// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Per-task phase within an autopilot run (drives the UI chips).
enum TaskPhase: Equatable {
    case queued
    case building
    case reviewing
    case fixing(pass: Int)
    case merging
    case resolvingConflict
    case done
    case blocked(reason: String)
}

/// Live state of one project's autopilot run. `@Observable` so the UI tracks phase/cost/round.
@MainActor
@Observable
final class AutopilotRun {
    let projectId: String
    let batchesRequested: Int
    var status: FeatureBuildRunner.Status = .running
    var currentRound: Int = 0
    var roundsCompleted: Int = 0
    var taskPhases: [String: TaskPhase] = [:]
    var costByTask: [String: Double] = [:]
    var findingsByTask: [String: [ReviewFinding]] = [:]
    var reportByTask: [String: ReviewReport] = [:]   // initial review per task, for the persisted report
    var budgetCapUsd: Double?
    var baseBranch: String = ""
    var integrationBranch: String = ""
    var lastError: String?
    let startedAt = Date()

    @ObservationIgnored var loopTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var deps: FeatureBuildRunner.Deps?

    /// Sum of every task's cumulative cost: build + fix passes (worker chains) plus the
    /// Opus review and any conflict-resolution spend, all folded into `costByTask`.
    var totalCostUsd: Double { costByTask.values.reduce(0, +) }

    init(projectId: String, batchesRequested: Int, budgetCapUsd: Double?) {
        self.projectId = projectId
        self.batchesRequested = batchesRequested
        self.budgetCapUsd = budgetCapUsd
    }
}

/// Drives a project's Kanban autonomously for up to N batches: build a round in parallel →
/// auto-review each finished task with Opus → auto-apply only critical/major fixes → merge into
/// the base branch → resolve conflicts with a dedicated worker → advance to the next round.
///
/// Reuses `TaskSpawner` (build/iterate), `AIAssistant` (structured review + conflict resolution),
/// `GitService` (merge), and `ExecutionPlanner` (rounds). One instance app-wide, keyed by project.
@MainActor
@Observable
final class FeatureBuildRunner {
    enum Status: Equatable {
        case running
        case stopping
        case paused(String)     // halted by a usage/rate limit; Resume to continue
        case finished
        case failed(String)
    }

    private(set) var runs: [String: AutopilotRun] = [:]
    private let logger = Logger(subsystem: "app.atelier", category: "autopilot")

    // Tuning / guardrails.
    private let maxFixPasses = 2
    private let maxRoundsCeiling = 50

    struct Deps {
        let project: Project
        let store: AppStore
        let spawner: TaskSpawner
        let server: ApprovalServer
        let approvalQueue: ApprovalQueue
        let apiKey: String
    }

    // MARK: - Public

    func run(for projectId: String) -> AutopilotRun? { runs[projectId] }

    func isActive(projectId: String) -> Bool {
        guard let r = runs[projectId] else { return false }
        switch r.status {
        case .running, .stopping, .paused: return true
        case .finished, .failed: return false
        }
    }

    func start(project: Project,
               batches: Int,
               budgetCapUsd: Double?,
               store: AppStore,
               spawner: TaskSpawner,
               server: ApprovalServer,
               approvalQueue: ApprovalQueue) {
        guard !isActive(projectId: project.id) else { return }
        let run = AutopilotRun(projectId: project.id,
                               batchesRequested: max(1, batches),
                               budgetCapUsd: budgetCapUsd)
        let deps = Deps(project: project, store: store, spawner: spawner, server: server,
                        approvalQueue: approvalQueue, apiKey: APIKeyResolver.resolve())
        run.deps = deps
        runs[project.id] = run
        run.loopTask = Task { @MainActor in await self.runLoop(run: run, deps: deps) }
    }

    /// Soft stop: no new spawns, let in-flight workers finish. `force` also SIGTERMs live workers.
    func stop(projectId: String, force: Bool) {
        guard let run = runs[projectId] else { return }
        if run.status == .running { run.status = .stopping }
        if force, let deps = run.deps {
            for taskId in run.taskPhases.keys { deps.spawner.cancel(taskId: taskId) }
        }
    }

    /// Drops a finished/failed/paused run so the project's control returns to idle.
    func clearRun(projectId: String) {
        guard let run = runs[projectId] else { return }
        if run.status == .running || run.status == .stopping { return }
        runs[projectId] = nil
    }

    /// Resumes a paused run (after a usage limit). Continues on the SAME feature branch:
    /// re-integrates anything left in review, then builds the remaining tasks.
    func resume(projectId: String) {
        guard let run = runs[projectId], case .paused = run.status, let deps = run.deps else { return }
        run.status = .running
        run.lastError = nil
        run.loopTask = Task { @MainActor in await self.runLoop(run: run, deps: deps) }
    }

    // MARK: - Loop

    private func runLoop(run: AutopilotRun, deps: Deps) async {
        // Resolve + guard the base branch.
        do {
            if run.integrationBranch.isEmpty {
                let base = try await GitService.currentBranch(projectPath: deps.project.path)
                guard base != "HEAD" else {
                    finish(run, .failed("Detached HEAD — check out a branch before running autopilot."))
                    return
                }
                // Everything merges into a fresh feature branch off the current one, so your
                // original branch is never touched. We present this branch at the end to review.
                let integration = "atelier/autopilot-\(Self.timestamp())"
                try await GitService.createIntegrationBranch(projectPath: deps.project.path, branch: integration)
                run.integrationBranch = integration
                run.baseBranch = integration   // task worktrees branch off this; merges land here
            } else {
                // Resume (e.g. after a usage-limit pause): the feature branch already exists.
                // Re-check it out, then integrate any tasks left in review before building more.
                try await GitService.checkoutBranch(projectPath: deps.project.path, branch: run.integrationBranch)
                for t in deps.store.tasks(in: deps.project.id, status: .review)
                        .sorted(by: { integrationOrder($0) < integrationOrder($1) }) {
                    if run.status != .running { break }
                    await reviewFixMerge(t, run: run, deps: deps)
                }
            }
        } catch {
            finish(run, .failed("Git setup failed: \(error.localizedDescription)"))
            return
        }

        var safety = 0
        while run.status == .running && run.roundsCompleted < run.batchesRequested {
            safety += 1
            if safety > maxRoundsCeiling { finish(run, .failed("Round ceiling reached.")); return }
            if overBudget(run) { finish(run, .failed(budgetMessage(run))); return }

            let allTasks = deps.store.tasks(in: deps.project.id)
            let todo = allTasks.filter { $0.status == .toDo }
            let wave = ExecutionPlanner.runnableNow(tasks: todo, allTasks: allTasks)
            if wave.isEmpty { break }   // nothing runnable now → natural finish (deadlock or done)

            run.currentRound += 1
            for t in wave { run.taskPhases[t.id] = .queued }

            // PHASE A — build the round in parallel. Unstructured @MainActor tasks (the same
            // pattern as TaskSpawner.start), awaited individually — withTaskGroup tripped Swift 6's
            // region-based isolation checker here. The parallelism is real: each build's
            // subprocess runs off the main actor inside `spawnAndAwait`.
            var buildTasks: [Task<Void, Never>] = []
            for task in wave {
                if run.status != .running || overBudget(run) { break }
                buildTasks.append(Task { @MainActor in await self.buildOne(task, run: run, deps: deps) })
            }
            for t in buildTasks { await t.value }
            if run.status != .running { break }

            // PHASE B — integrate serially (merges share the base branch + index).
            for task in wave.sorted(by: { integrationOrder($0) < integrationOrder($1) }) {
                if run.status != .running || overBudget(run) { break }
                guard let latest = deps.store.taskByID(task.id), latest.status == .review else { continue }
                await reviewFixMerge(latest, run: run, deps: deps)
            }
            run.roundsCompleted += 1
        }

        if run.status == .running || run.status == .stopping { finish(run, .finished) }
    }

    // MARK: - Per-task pipeline

    private func buildOne(_ task: AtelierTask, run: AutopilotRun, deps: Deps) async {
        run.taskPhases[task.id] = .building
        let active = await deps.spawner.spawnAndAwait(task: task,
                                                      project: deps.project,
                                                      apiKey: deps.apiKey,
                                                      store: deps.store,
                                                      server: deps.server,
                                                      approvalQueue: deps.approvalQueue,
                                                      autopilot: true)
        if let active { run.costByTask[task.id] = active.state.totalCostUsd }
        if active?.agent.status != .completed {
            // A usage/rate limit isn't the task's fault — pause the whole run (Resume rebuilds it)
            // rather than permanently blocking the task.
            if let active, active.state.looksUsageLimited {
                await pauseForUsage(task, run: run, deps: deps)
            } else {
                await block(task, "build did not complete (\(active?.agent.status.rawValue ?? "no run"))",
                            run: run, deps: deps)
            }
        }
        // On success `execute` already promoted the task to .review; Phase B picks it up.
    }

    private func reviewFixMerge(_ task: AtelierTask, run: AutopilotRun, deps: Deps) async {
        guard let agent = try? await deps.store.agentsForTask(task.id).first,
              !agent.worktreePath.isEmpty else {
            await block(task, "no agent/worktree to review", run: run, deps: deps); return
        }
        let worktreePath = agent.worktreePath
        let branch = agent.branch.isEmpty ? "worktree-\(task.id)" : agent.branch

        // Review (structured).
        run.taskPhases[task.id] = .reviewing
        var report: ReviewReport
        do {
            report = try await AIAssistant.reviewWorktree(taskTitle: task.title,
                                                          taskDescription: task.descriptionMd ?? "",
                                                          worktreePath: worktreePath,
                                                          baseBranch: run.baseBranch,
                                                          apiKey: deps.apiKey)
            run.findingsByTask[task.id] = report.findings
            run.reportByTask[task.id] = report   // the initial review = what was found pre-fix
            run.costByTask[task.id, default: 0] += report.costUsd
        } catch {
            await block(task, "review failed: \(error.localizedDescription)", run: run, deps: deps); return
        }

        // Fix loop — only blocking (critical/major) findings, capped.
        var pass = 0
        while !report.blockingFindings.isEmpty && pass < maxFixPasses && run.status == .running {
            pass += 1
            run.taskPhases[task.id] = .fixing(pass: pass)
            guard let prior = try? await deps.store.agentsForTask(task.id).first,
                  prior.sessionId?.isEmpty == false else {
                await block(task, "can't resume session to apply fixes", run: run, deps: deps); return
            }
            let result = await deps.spawner.iterateAndAwait(task: task,
                                                            project: deps.project,
                                                            priorAgent: prior,
                                                            message: fixMessage(report.blockingFindings),
                                                            apiKey: deps.apiKey,
                                                            store: deps.store,
                                                            server: deps.server,
                                                            approvalQueue: deps.approvalQueue,
                                                            autopilot: true)
            if let result { run.costByTask[task.id] = result.state.totalCostUsd }
            // A usage limit mid-fix pauses the run; the task stays in Review so Resume re-integrates it.
            if let result, result.agent.status != .completed, result.state.looksUsageLimited {
                await pauseForUsage(task, run: run, deps: deps); return
            }
            do {
                report = try await AIAssistant.reviewWorktree(taskTitle: task.title,
                                                              taskDescription: task.descriptionMd ?? "",
                                                              worktreePath: worktreePath,
                                                              baseBranch: run.baseBranch,
                                                              apiKey: deps.apiKey)
                run.findingsByTask[task.id] = report.findings
                run.costByTask[task.id, default: 0] += report.costUsd
            } catch {
                await block(task, "re-review failed: \(error.localizedDescription)", run: run, deps: deps); return
            }
        }
        if !report.blockingFindings.isEmpty {
            await block(task, "still \(report.blockingFindings.count) blocking issue(s) after \(maxFixPasses) fix passes",
                        run: run, deps: deps)
            return
        }

        // Merge into base.
        run.taskPhases[task.id] = .merging
        do {
            _ = try await GitService.commitWorktree(projectPath: deps.project.path,
                                                    taskId: task.id,
                                                    message: "Atelier autopilot: finalize \(task.title)")
            let result = try await GitService.merge(into: run.baseBranch,
                                                    branch: branch,
                                                    projectPath: deps.project.path)
            switch result {
            case .clean, .upToDate:
                await markMerged(task, run: run, deps: deps,
                                 outcome: pass > 0 ? "Merged after \(pass) fix pass\(pass == 1 ? "" : "es")" : "Merged cleanly")
            case .conflict(let files):
                run.taskPhases[task.id] = .resolvingConflict
                let (resolved, conflictCost) = try await AIAssistant.resolveMergeConflict(projectPath: deps.project.path,
                                                                          baseBranch: run.baseBranch,
                                                                          branch: branch,
                                                                          conflictFiles: files,
                                                                          taskTitle: task.title,
                                                                          apiKey: deps.apiKey)
                run.costByTask[task.id, default: 0] += conflictCost
                if resolved {
                    await markMerged(task, run: run, deps: deps, outcome: "Merged after auto-resolving merge conflicts")
                } else {
                    try? await GitService.abortMerge(projectPath: deps.project.path)
                    await block(task, "merge conflict couldn't be auto-resolved", run: run, deps: deps)
                }
            }
        } catch {
            try? await GitService.abortMerge(projectPath: deps.project.path)
            await block(task, "merge failed: \(error.localizedDescription)", run: run, deps: deps)
        }
    }

    // MARK: - Helpers

    private func markMerged(_ task: AtelierTask, run: AutopilotRun, deps: Deps, outcome: String) async {
        writeAutopilotReport(task: task, project: deps.project, report: run.reportByTask[task.id], outcome: outcome)
        try? await deps.store.updateTaskStatus(task, to: .done)
        try? await GitService.removeWorktree(projectPath: deps.project.path, taskId: task.id, force: false)
        run.taskPhases[task.id] = .done
    }

    private func block(_ task: AtelierTask, _ reason: String, run: AutopilotRun, deps: Deps) async {
        logger.warning("autopilot blocked \(task.id, privacy: .public): \(reason, privacy: .public)")
        writeAutopilotReport(task: task, project: deps.project, report: run.reportByTask[task.id], outcome: "Blocked — \(reason)")
        run.taskPhases[task.id] = .blocked(reason: reason)
        try? await deps.store.updateTaskStatus(task, to: .blocked)
    }

    /// Persists a human-readable per-task report to `<project>/.atelier/autopilot/<taskId>.md`,
    /// surfaced in the task detail so the review + outcome stay consultable after the run.
    private func writeAutopilotReport(task: AtelierTask, project: Project, report: ReviewReport?, outcome: String) {
        var md = "# Autopilot — \(task.title)\n\n"
        md += "- **Task:** `\(task.id)`\n"
        md += "- **Outcome:** \(outcome)\n"
        md += "- **When:** \(Date().formatted(date: .abbreviated, time: .shortened))\n\n"
        if let report {
            md += "## Review\n\n**Verdict:** \(report.verdict.rawValue)\n\n"
            if !report.summary.isEmpty { md += "\(report.summary)\n\n" }
            if report.findings.isEmpty {
                md += "_No findings._\n"
            } else {
                md += "### Findings\n\n"
                for f in report.findings.sorted(by: { severityRank($0.severity) < severityRank($1.severity) }) {
                    let loc = [f.file, f.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
                    md += "- **[\(f.severity.rawValue)]**\(loc.isEmpty ? "" : " `\(loc)`") — \(f.summary)\n"
                    if !f.suggestedFix.isEmpty { md += "    - _Fix:_ \(f.suggestedFix)\n" }
                }
                md += "\n_Only critical/major findings are auto-fixed; minor/cosmetic are left as-is._\n"
            }
        } else {
            md += "_No review was produced for this task._\n"
        }
        let dir = URL(fileURLWithPath: project.path).appendingPathComponent(".atelier/autopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? md.write(to: dir.appendingPathComponent("\(task.id).md"), atomically: true, encoding: .utf8)
    }

    private func severityRank(_ s: ReviewSeverity) -> Int {
        switch s {
        case .critical: return 0
        case .major: return 1
        case .minor: return 2
        case .cosmetic: return 3
        }
    }

    private func finish(_ run: AutopilotRun, _ status: Status) {
        run.status = status
        if case .failed(let msg) = status { run.lastError = msg }
    }

    // MARK: - Usage-limit handling

    /// A usage/rate limit stopped a worker. Pause the run (no new spawns) and roll a half-built
    /// task (stuck In Progress) back to To Do so Resume rebuilds it on the same feature branch; a
    /// task already in Review is left there so Resume just re-integrates it.
    private func pauseForUsage(_ task: AtelierTask, run: AutopilotRun, deps: Deps) async {
        logger.notice("autopilot paused on usage limit at \(task.id, privacy: .public)")
        if let latest = deps.store.taskByID(task.id), latest.status == .inProgress {
            try? await deps.store.updateTaskStatus(latest, to: .toDo)
        }
        run.taskPhases[task.id] = .queued
        let reason = "Usage limit reached while building “\(task.title)”. Resume once your limit resets."
        run.status = .paused(reason)
        run.lastError = reason
    }

    private func overBudget(_ run: AutopilotRun) -> Bool {
        guard let cap = run.budgetCapUsd, cap > 0 else { return false }
        return run.totalCostUsd >= cap
    }

    private func budgetMessage(_ run: AutopilotRun) -> String {
        String(format: "Budget cap reached — $%.2f spent of $%.2f.", run.totalCostUsd, run.budgetCapUsd ?? 0)
    }

    private func fixMessage(_ findings: [ReviewFinding]) -> String {
        let list = findings.enumerated()
            .map { "\($0.offset + 1). \($0.element.oneLine)\n   Fix: \($0.element.suggestedFix)" }
            .joined(separator: "\n")
        return """
        A reviewer found blocking issues in your work. Fix ONLY these — do not refactor anything
        else, and ignore any minor/cosmetic nits. Keep the build and tests green, and commit when done.

        \(list)
        """
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Merge order within a round: priority first (critical→low), then task id for determinism.
    private func integrationOrder(_ t: AtelierTask) -> (Int, String) {
        let rank: Int
        switch t.priority {
        case .critical: rank = 0
        case .high: rank = 1
        case .medium: rank = 2
        case .low: rank = 3
        case nil: rank = 4
        }
        return (rank, t.id)
    }
}
