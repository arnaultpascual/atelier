// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Per-task phase within an autopilot run (drives the UI chips).
enum TaskPhase: Equatable {
    case queued
    case building
    case buildingVerify     // opt-in pre-merge build verification (not a test run)
    case testing            // running the mode's fast test suite (TDD gate / pre-merge)
    case reviewing
    case fixing(pass: Int)
    case merging
    case verifyingMerge     // post-merge regression re-run on the integration branch
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
    var costByTask: [String: Double] = [:]              // worker chain (build + fix passes)
    var reviewCostByTask: [String: Double] = [:]        // Opus review + conflict resolution
    var fixPassesByTask: [String: Int] = [:]            // carried from review phase to merge phase
    var readyToMerge: Set<String> = []                  // passed review, queued for the serial merge
    var findingsByTask: [String: [ReviewFinding]] = [:]
    var reportByTask: [String: ReviewReport] = [:]   // initial review per task, for the persisted report
    var alignmentByTask: [String: AIAssistant.AlignmentVerdict] = [:]   // test-change alignment verdict per task
    var buildVerifyByTask: [String: TestRunner.CommandOutcome] = [:]    // opt-in build-verify result per task (for the dossier)
    var budgetCapUsd: Double?
    var baseBranch: String = ""
    var integrationBranch: String = ""
    var originalBase: String = ""    // the branch the integration was cut from (for the combined diff / final merge)
    var lastError: String?
    var synthesisCostUsd: Double = 0     // final FEATURE synthesis pass (re-test fix + conformity + deliverable)
    var deliverablePath: String?         // <project>/FEATURE-<slug>.md once the synthesis writes it
    let startedAt = Date()

    @ObservationIgnored var loopTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var deps: FeatureBuildRunner.Deps?
    /// One-shot auto-resume after a usage-limit pause (scheduled on the reset time + margin).
    @ObservationIgnored var autoResumeTask: Task<Void, Never>?
    var didAutoResume = false   // only one automatic attempt; after it, resumption is manual

    /// Sum of every task's cost: worker chains (build + fix passes) in `costByTask`, plus Opus
    /// review and conflict-resolution spend in `reviewCostByTask`, plus the final synthesis pass.
    var totalCostUsd: Double {
        costByTask.values.reduce(0, +) + reviewCostByTask.values.reduce(0, +) + synthesisCostUsd
    }

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
        run.autoResumeTask?.cancel(); run.autoResumeTask = nil   // cancel any pending auto-resume
        if run.status == .running { run.status = .stopping }
        if force, let deps = run.deps {
            for taskId in run.taskPhases.keys { deps.spawner.cancel(taskId: taskId) }
        }
    }

    /// Drops a finished/failed/paused run so the project's control returns to idle.
    func clearRun(projectId: String) {
        guard let run = runs[projectId] else { return }
        if run.status == .running || run.status == .stopping { return }
        run.autoResumeTask?.cancel(); run.autoResumeTask = nil
        runs[projectId] = nil
    }

    /// Resumes a paused run (after a usage limit). Continues on the SAME feature branch:
    /// re-integrates anything left in review, then builds the remaining tasks.
    func resume(projectId: String) {
        guard let run = runs[projectId], case .paused = run.status, let deps = run.deps else { return }
        run.autoResumeTask?.cancel(); run.autoResumeTask = nil   // manual (or auto) resume takes over
        run.status = .running
        run.lastError = nil
        run.loopTask = Task { @MainActor in await self.runLoop(run: run, deps: deps) }
    }

    // MARK: - Loop

    private func runLoop(run: AutopilotRun, deps: Deps) async {
        // Toolchain preflight: an unattended run that can't even run its tests is pointless and
        // would mislabel tooling failures as test failures. Refuse to start with install guidance.
        let toolReport = await ToolchainChecker.check(profile: modeProfile(deps), projectPath: deps.project.path)
        if !toolReport.ready {
            let hints = toolReport.requiredMissing.map { "\($0.label): \($0.installHint)" }.joined(separator: " · ")
            finish(run, .failed("Toolchain not ready — \(toolReport.missingSummary). \(hints)"))
            return
        }

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
                run.originalBase = base        // remember where we branched from
                run.baseBranch = integration   // task worktrees branch off this; merges land here
            } else {
                // Resume (e.g. after a usage-limit pause): the feature branch already exists.
                // Re-check it out, then integrate any tasks left in review before building more.
                try await GitService.checkoutBranch(projectPath: deps.project.path, branch: run.integrationBranch)
                for t in deps.store.tasks(in: deps.project.id, status: .review)
                        .sorted(by: { integrationOrder($0) < integrationOrder($1) }) {
                    if run.status != .running { break }
                    run.readyToMerge.remove(t.id)
                    await reviewAndFix(t, run: run, deps: deps)
                    if run.status == .running, run.readyToMerge.contains(t.id) {
                        await mergeReviewed(t, run: run, deps: deps)
                    }
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

            // PHASE B1 — review + auto-fix in parallel. Each task only touches its own
            // worktree, so reviews/fixes are independent; same unstructured @MainActor
            // pattern as the builds above.
            run.readyToMerge.subtract(wave.map(\.id))
            var reviewTasks: [Task<Void, Never>] = []
            for task in wave {
                if run.status != .running { break }
                guard let latest = deps.store.taskByID(task.id), latest.status == .review else { continue }
                reviewTasks.append(Task { @MainActor in await self.reviewAndFix(latest, run: run, deps: deps) })
            }
            for t in reviewTasks { await t.value }
            if run.status != .running { break }

            // PHASE B2 — merge serially (all merges share the base branch + index).
            for task in wave.sorted(by: { integrationOrder($0) < integrationOrder($1) }) {
                if run.status != .running || overBudget(run) { break }
                guard run.readyToMerge.contains(task.id),
                      let latest = deps.store.taskByID(task.id), latest.status == .review else { continue }
                await mergeReviewed(latest, run: run, deps: deps)
            }
            run.roundsCompleted += 1
        }

        // Automatic final FEATURE pass: once everything runnable has merged, re-test the integration
        // branch (+ bounded fix), check conformity to the demand, and write the deliverable at the
        // project root. Only on a clean completion (not a user stop / usage pause); best-effort.
        if run.status == .running {
            await runFeatureSynthesis(run: run, deps: deps)
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
        guard active?.agent.status == .completed else {
            // A usage/rate limit isn't the task's fault — pause the whole run (Resume rebuilds it)
            // rather than permanently blocking the task.
            if let active, active.state.looksUsageLimited {
                await pauseForUsage(task, run: run, deps: deps)
            } else {
                await block(task, "build did not complete (\(active?.agent.status.rawValue ?? "no run"))",
                            run: run, deps: deps)
            }
            return
        }
        // The shared TDD gate (TaskSpawner.execute) promoted the task to .review iff its tests
        // passed. If it stayed In Progress, tests are red — fix them within the cap so red tasks
        // don't silently stall outside Phase B (which only picks up .review tasks).
        guard let latest = deps.store.taskByID(task.id), latest.status == .inProgress else { return }
        let profile = modeProfile(deps)
        guard !profile.build.fastTestCommands.isEmpty else {
            // No test command but somehow unpromoted — promote it so Phase B can review it.
            await applyGate(task.id, deps: deps, state: .noTests, clearSummary: true, status: .review)
            return
        }
        guard let agent = try? await deps.store.agentsForTask(task.id).first, !agent.worktreePath.isEmpty else {
            await block(task, "tests red and no worktree to fix", run: run, deps: deps); return
        }
        let green = await fixRedTests(task, worktreePath: agent.worktreePath, run: run, deps: deps)
        if run.status != .running { return }
        if green {
            await applyGate(task.id, deps: deps, status: .review)   // testState already .green
        } else {
            await block(task, "tests still red after \(maxFixPasses) fix pass\(maxFixPasses == 1 ? "" : "es")",
                        run: run, deps: deps)
        }
    }

    /// Review + auto-fix a finished worktree. Parallel-safe: only touches this task's own
    /// worktree (reviews diff it read-only; fixes resume its session). On success the task is
    /// added to `readyToMerge` for the serial merge phase; otherwise it's blocked / the run pauses.
    private func reviewAndFix(_ task: AtelierTask, run: AutopilotRun, deps: Deps) async {
        guard let agent = try? await deps.store.agentsForTask(task.id).first,
              !agent.worktreePath.isEmpty else {
            await block(task, "no agent/worktree to review", run: run, deps: deps); return
        }
        let worktreePath = agent.worktreePath
        let agentBranch = agent.branch.isEmpty ? "worktree-\(task.id)" : agent.branch

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
            run.reviewCostByTask[task.id, default: 0] += report.costUsd
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
                                                            message: fixMessage(report.blockingFindings, taskId: task.id),
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
                run.reviewCostByTask[task.id, default: 0] += report.costUsd
            } catch {
                await block(task, "re-review failed: \(error.localizedDescription)", run: run, deps: deps); return
            }
        }
        if !report.blockingFindings.isEmpty {
            await block(task, "still \(report.blockingFindings.count) blocking issue(s) after \(maxFixPasses) fix passes",
                        run: run, deps: deps)
            return
        }
        // Pre-merge TDD gate: the Opus fix-loop may have changed code, so re-run the suite.
        // (Tests were green at build time to reach Review; this catches fix-induced regressions.)
        var alignmentPasses = 0
        let profile = modeProfile(deps)
        if !profile.build.fastTestCommands.isEmpty {
            run.taskPhases[task.id] = .testing
            let testResult = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: deps.project.path)
            if testResult.toolchainMissing {
                // Tooling vanished mid-run (start was preflighted). Surface, skip gating, let it merge.
                await applyGate(task.id, deps: deps, state: .toolchainMissing, summary: testResult.summaryLine)
                run.fixPassesByTask[task.id] = pass
                run.readyToMerge.insert(task.id)
                run.taskPhases[task.id] = .reviewing
                return
            }
            await applyGate(task.id, deps: deps, state: testResult.passed ? .green : .red, summary: testResult.summaryLine)
            if !testResult.passed {
                let green = await fixRedTests(task, worktreePath: worktreePath, run: run, deps: deps)
                if run.status != .running { return }
                if !green {
                    await block(task, "tests red after review fixes (\(maxFixPasses) pass cap)", run: run, deps: deps)
                    return
                }
            }
        }

        // Test-change ALIGNMENT review (drift): the suite is green, but if tests changed we ask an
        // agent — was the change necessary, and does the implementation STILL answer the demand
        // (local + global feature)? When not, we feed concrete fix instructions back to the worker
        // and iterate to converge (bounded by maxFixPasses); we block only as a last resort.
        if !profile.build.testDiscoveryGlobs.isEmpty {
            let signals = await TestIntegrityChecker.inspect(profile: profile, projectPath: deps.project.path,
                                                             branch: agentBranch, taskId: task.id)
            var note = TestIntegrityChecker.declaredNote(worktreePath: worktreePath, taskId: task.id)
            if signals.anyTestChange && !signals.looksWeakened && note != nil {
                // Declared, non-weakening evolution — trust it.
                await applyGate(task.id, deps: deps, integrity: .evolved, changeNote: note)
            } else if signals.anyTestChange {
                // Weakened or undeclared change → scrutinize, then repair-loop until aligned.
                run.taskPhases[task.id] = .testing
                let first: AIAssistant.AlignmentVerdict
                do {
                    first = try await AIAssistant.reviewTestAlignment(
                        taskTitle: task.title, brief: task.descriptionMd ?? "",
                        globalContext: featureContext(run, deps, excluding: task.id), testDiff: signals.diffText,
                        declaredNote: note, mechanicalSummary: signals.summaryLine,
                        worktreePath: worktreePath, baseBranch: run.baseBranch, apiKey: deps.apiKey)
                } catch {
                    // Reviewer never ran (claude down / timeout) — NOT a weakening. Surface as
                    // unavailable (recoverable on resume); never stamp .suspect.
                    await applyGate(task.id, deps: deps, integrity: .unevaluated, changeNote: note, clearChangeNote: note == nil)
                    await block(task, "alignment review unavailable: \(error.localizedDescription)", run: run, deps: deps)
                    return
                }
                run.alignmentByTask[task.id] = first
                run.reviewCostByTask[task.id, default: 0] += first.costUsd

                var current = first
                while !current.aligned, alignmentPasses < maxFixPasses, run.status == .running {
                    alignmentPasses += 1
                    run.taskPhases[task.id] = .fixing(pass: pass + alignmentPasses)
                    guard let prior = try? await deps.store.agentsForTask(task.id).first,
                          prior.sessionId?.isEmpty == false else { break }
                    let r = await deps.spawner.iterateAndAwait(
                        task: task, project: deps.project, priorAgent: prior,
                        message: alignmentFixMessage(current, taskId: task.id), apiKey: deps.apiKey,
                        store: deps.store, server: deps.server, approvalQueue: deps.approvalQueue, autopilot: true)
                    if let r { run.costByTask[task.id] = r.state.totalCostUsd }
                    if let r, r.agent.status != .completed, r.state.looksUsageLimited {
                        await pauseForUsage(task, run: run, deps: deps); return
                    }
                    // Tests must stay green after the alignment fix; recover once if they broke.
                    let t = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: deps.project.path)
                    await applyGate(task.id, deps: deps, state: t.passed ? .green : .red, summary: t.summaryLine)
                    if !t.passed {
                        let green = await fixRedTests(task, worktreePath: worktreePath, run: run, deps: deps)
                        if run.status != .running { return }
                        if !green { await block(task, "tests red during alignment fix", run: run, deps: deps); return }
                    }
                    let s2 = await TestIntegrityChecker.inspect(profile: profile, projectPath: deps.project.path,
                                                                branch: agentBranch, taskId: task.id)
                    note = TestIntegrityChecker.declaredNote(worktreePath: worktreePath, taskId: task.id)
                    do {
                        current = try await AIAssistant.reviewTestAlignment(
                            taskTitle: task.title, brief: task.descriptionMd ?? "",
                            globalContext: featureContext(run, deps, excluding: task.id), testDiff: s2.diffText,
                            declaredNote: note, mechanicalSummary: s2.summaryLine,
                            worktreePath: worktreePath, baseBranch: run.baseBranch, apiKey: deps.apiKey)
                    } catch {
                        await applyGate(task.id, deps: deps, integrity: .unevaluated, changeNote: note, clearChangeNote: note == nil)
                        await block(task, "alignment review unavailable mid-repair: \(error.localizedDescription)", run: run, deps: deps)
                        return
                    }
                    run.alignmentByTask[task.id] = current
                    run.reviewCostByTask[task.id, default: 0] += current.costUsd
                }

                if current.aligned {
                    await applyGate(task.id, deps: deps, integrity: .evolved, changeNote: note, clearChangeNote: note == nil)
                } else {
                    await applyGate(task.id, deps: deps, integrity: .suspect, changeNote: note, clearChangeNote: note == nil)
                    await block(task, "test change doesn't answer the demand after \(maxFixPasses) pass(es): \(current.rationale)",
                                run: run, deps: deps)
                    return
                }
            } else {
                await applyGate(task.id, deps: deps, integrity: .intact, clearChangeNote: true)
            }
        }

        // Opt-in build verification (OFF by default — Atelier stays build-independent). Only runs
        // when the project enabled it AND a (mode or custom) build command exists.
        if !(await verifyBuild(task, worktreePath: worktreePath, run: run, deps: deps)) {
            if run.status != .running { return }   // paused (usage limit) — leave for resume
            await block(task, "build verification failed after \(maxFixPasses) fix pass(es)", run: run, deps: deps)
            return
        }

        // Passed review + tests + alignment (+ optional build) — queue for the serial merge phase.
        run.fixPassesByTask[task.id] = pass + alignmentPasses
        run.readyToMerge.insert(task.id)
        run.taskPhases[task.id] = .reviewing   // holds here until B2 merges it
    }

    /// Merge a reviewed task's worktree into the shared base branch. MUST run serially across
    /// tasks — every merge touches the same base branch + index.
    private func mergeReviewed(_ task: AtelierTask, run: AutopilotRun, deps: Deps) async {
        guard let agent = try? await deps.store.agentsForTask(task.id).first,
              !agent.worktreePath.isEmpty else {
            await block(task, "no worktree to merge", run: run, deps: deps); return
        }
        let branch = agent.branch.isEmpty ? "worktree-\(task.id)" : agent.branch
        let pass = run.fixPassesByTask[task.id] ?? 0

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
                run.reviewCostByTask[task.id, default: 0] += conflictCost
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
        let profile = modeProfile(deps)
        let hasTests = !profile.build.fastTestCommands.isEmpty
        var summary = outcome
        var toolchainMissing = false

        // Post-merge re-verify on the INTEGRATION branch — UNIT TESTS ONLY (no app build, which can
        // need a device/target/remote step). Catches cross-task breakage between parallel merges.
        // Runs BEFORE removing the worktree so a regression stays inspectable.
        if hasTests {
            run.taskPhases[task.id] = .verifyingMerge
            let result = await TestRunner.runFastTests(profile: profile, worktreePath: deps.project.path, mainRepoPath: deps.project.path)
            if result.toolchainMissing {
                // Can't re-verify without tooling — surface, don't falsely flag a regression.
                toolchainMissing = true
                await applyGate(task.id, deps: deps, state: .toolchainMissing, summary: result.summaryLine)
            } else if !result.passed {
                await applyGate(task.id, deps: deps, state: .regressed,
                                summary: "Post-merge regression: \(result.summaryLine)")
                await block(task, "post-merge regression: \(result.summaryLine)", run: run, deps: deps)
                return   // leave the worktree on disk for inspection
            } else {
                summary = result.summaryLine
            }
        }

        writeAutopilotReport(task: task, project: deps.project, report: run.reportByTask[task.id], outcome: outcome)
        // Generate the two-part test dossier while the worktree is still on disk. Sourced from the
        // WORKTREE (not the integration branch) so Part A's results and Part B's diff describe the
        // same, task-scoped tree (the integration branch also contains sibling tasks).
        await generateDossier(task: task, run: run, deps: deps, profile: profile)
        if hasTests && !toolchainMissing {
            await applyGate(task.id, deps: deps, state: .greenMerged, summary: summary, status: .done)
        } else {
            // No tests, or tooling missing → just mark done (preserve a .toolchainMissing state).
            await applyGate(task.id, deps: deps, status: .done)
        }
        try? await GitService.removeWorktree(projectPath: deps.project.path, taskId: task.id, force: false)
        run.taskPhases[task.id] = .done
    }

    /// Builds + persists the test dossier for a just-merged task. Best-effort: a failure never
    /// blocks the merge. Runs the suite/build in the WORKTREE (still on disk) so Part A's results and
    /// Part B's diff describe the same, task-scoped tree.
    private func generateDossier(task: AtelierTask, run: AutopilotRun, deps: Deps, profile: ProjectProfile) async {
        guard let agent = try? await deps.store.agentsForTask(task.id).first,
              !agent.worktreePath.isEmpty,
              FileManager.default.fileExists(atPath: agent.worktreePath) else { return }
        let branch = agent.branch.isEmpty ? "worktree-\(task.id)" : agent.branch
        let result = await TestRunner.runFastTests(profile: profile, worktreePath: agent.worktreePath, mainRepoPath: deps.project.path, retriesOnRed: 0)
        // No app build here — stays build-independent. If opt-in build-verify ran pre-merge, reuse
        // its result for Part A (don't re-build).
        let dossier = await DossierBuilder.build(
            task: task, profile: profile, project: deps.project, branch: branch,
            worktreePath: agent.worktreePath, testResult: result, buildOutcome: run.buildVerifyByTask[task.id],
            review: run.reportByTask[task.id], alignment: run.alignmentByTask[task.id], apiKey: deps.apiKey)
        TestDossierStore.persist(dossier, projectPath: deps.project.path)
        run.reviewCostByTask[task.id, default: 0] += dossier.costUsd
    }

    // MARK: - Feature synthesis (automatic final pass)

    /// Runs ONCE when every runnable task has merged: re-tests the whole integrated feature on the
    /// integration branch (with a bounded fix loop), measures final coverage, judges conformity to
    /// the aggregated demand, and writes `FEATURE-<slug>.md` at the PROJECT ROOT. Best-effort — it
    /// never fails the run; the deliverable reports honestly (incl. a still-red suite) if no fix lands.
    private func runFeatureSynthesis(run: AutopilotRun, deps: Deps) async {
        let merged: [AtelierTask] = run.taskPhases.compactMap { (id, phase) in
            guard phase == .done, let t = deps.store.taskByID(id) else { return nil }
            return t
        }.sorted { $0.id < $1.id }
        guard !merged.isEmpty else { return }   // nothing built → no deliverable

        let blocked: [(task: AtelierTask, reason: String)] = run.taskPhases.compactMap { (id, phase) in
            guard case .blocked(let reason) = phase, let t = deps.store.taskByID(id) else { return nil }
            return (t, reason)
        }.sorted { $0.task.id < $1.task.id }

        // "Attente": tasks still To Do / In Progress that depend on a run-scoped task which never
        // reached .done (it blocked or didn't finish) — so the dependency graph correctly never ran
        // them. Surfaced in the deliverable so a stalled wait isn't silently invisible.
        let runScope = Set(run.taskPhases.keys)
        let allTasks = deps.store.tasks(in: deps.project.id)
        let unfinishedScoped = Set(allTasks.filter { runScope.contains($0.id) && $0.status != .done }.map(\.id))
        let stalled = allTasks.filter { t in
            (t.status == .toDo || t.status == .inProgress) && !runScope.contains(t.id)
                && t.dependsOn.contains { unfinishedScoped.contains($0) }
        }.sorted { $0.id < $1.id }

        let profile = modeProfile(deps)
        // Merges + resume leave us on the integration branch, but be safe.
        try? await GitService.checkoutBranch(projectPath: deps.project.path, branch: run.integrationBranch)

        // (a) Re-test the whole integrated feature; bounded fix loop if red (tooling-missing is
        // surfaced, not fixed). The integration branch is Atelier's own isolated branch, so the fix
        // worker edits it in place (no worktree/merge dance).
        var testResult: TestRunner.Result? = nil
        if !profile.build.fastTestCommands.isEmpty {
            var result = await TestRunner.runFastTests(profile: profile, worktreePath: deps.project.path, mainRepoPath: deps.project.path)
            var pass = 0
            while !result.passed && !result.toolchainMissing && pass < maxFixPasses && run.status == .running {
                pass += 1
                let outcome = await deps.spawner.runManagedWorker(
                    label: "feature-fix",
                    prompt: featureFixPrompt(result.summaryLine),
                    workingDirectory: deps.project.path,
                    project: deps.project, model: ModelRouter.latestOpus, apiKey: deps.apiKey,
                    store: deps.store, server: deps.server, approvalQueue: deps.approvalQueue)
                run.synthesisCostUsd += outcome.costUsd
                if outcome.looksUsageLimited { break }   // best-effort — don't pause the whole run for synthesis
                result = await TestRunner.runFastTests(profile: profile, worktreePath: deps.project.path, mainRepoPath: deps.project.path)
            }
            testResult = result
        }

        // (a') optional build-verify (opt-in) on the integration branch.
        var buildOutcome: TestRunner.CommandOutcome? = nil
        if deps.project.buildVerifyBeforeMerge, let cmd = deps.project.resolvedVerifyBuildCommand(profile: profile) {
            buildOutcome = await TestRunner.runCommand(cmd, worktreePath: deps.project.path, profile: profile, mainRepoPath: deps.project.path)
        }

        // Measure final coverage once (string for the deliverable + rate for the soft-round check).
        var coverageStr: String? = nil
        var coverageRate: Double? = nil
        if (testResult?.passed ?? false), profile.build.coverageCommand != nil {
            coverageStr = await DossierBuilder.measureCoverage(profile: profile, project: deps.project,
                                                               worktreePath: deps.project.path, gateGreen: true)
            coverageRate = DossierBuilder.coverageLineRate(worktreePath: deps.project.path)
        }

        // (3c) SOFT coverage-improvement round (opt-in): below the aim → one tests-first round on the
        // integration branch (in place), then re-test (stay green) + re-measure. Never a gate.
        if deps.project.coverageImprovementRound, run.status == .running,
           let target = profile.build.coverageTarget, let rate = coverageRate, rate * 100 < Double(target) {
            let outcome = await deps.spawner.runManagedWorker(
                label: "coverage-round",
                prompt: coverageRoundPrompt(current: rate * 100, target: target),
                workingDirectory: deps.project.path,
                project: deps.project, model: ModelRouter.latestOpus, apiKey: deps.apiKey,
                store: deps.store, server: deps.server, approvalQueue: deps.approvalQueue)
            run.synthesisCostUsd += outcome.costUsd
            if !outcome.looksUsageLimited {
                let after = await TestRunner.runFastTests(profile: profile, worktreePath: deps.project.path, mainRepoPath: deps.project.path)
                testResult = after
                if after.passed {   // only adopt the new numbers if the suite is still green
                    coverageStr = await DossierBuilder.measureCoverage(profile: profile, project: deps.project,
                                                                       worktreePath: deps.project.path, gateGreen: true)
                    coverageRate = DossierBuilder.coverageLineRate(worktreePath: deps.project.path)
                }
            }
        }

        // (b)+(c) conformity + recette + deliverable, written at the project root. Compute the
        // review rollup here (on the actor) so the builder takes only plain Sendable values.
        let reviewRollup = featureReviewRollup(run: run, mergedTasks: merged)
        let deliverable = await FeatureDeliverable.build(
            integrationBranch: run.integrationBranch, baseBranch: run.originalBase,
            project: deps.project, profile: profile,
            mergedTasks: merged, blockedTasks: blocked, stalledTasks: stalled, reviewRollup: reviewRollup,
            testResult: testResult, buildOutcome: buildOutcome, coverage: coverageStr, apiKey: deps.apiKey)
        run.synthesisCostUsd += deliverable.costUsd
        let url = FeatureDeliverableStore.persist(deliverable, projectPath: deps.project.path)
        run.deliverablePath = url.path
        logger.notice("feature synthesis wrote \(url.lastPathComponent, privacy: .public)")
    }

    /// One-line review rollup across the merged tasks, from the per-task reports collected during
    /// the run (read on the actor; passed to the deliverable builder as a plain string).
    private func featureReviewRollup(run: AutopilotRun, mergedTasks: [AtelierTask]) -> String {
        var blocking = 0, total = 0
        for t in mergedTasks {
            if let report = run.reportByTask[t.id] {
                total += report.findings.count
                blocking += report.blockingFindings.count
            }
        }
        if total == 0 { return "no review findings recorded" }
        return "\(total) finding(s) across tasks, \(blocking) were blocking (all resolved before merge)"
    }

    private func coverageRoundPrompt(current: Double, target: Int) -> String {
        """
        This feature's line coverage is \(String(format: "%.1f", current))%, below the \(target)% aim.
        Add UNIT TESTS ONLY (no production-code changes unless a test reveals a real bug) to raise
        coverage toward \(target)% — prioritise the least-covered, highest-risk paths: error handling,
        edge cases, and branches. Write meaningful assertions, never trivial/placeholder tests. Keep
        the whole suite green (the mode's test command must still exit 0). This is a soft target, not
        a hard gate — get as close as you reasonably can without padding. Commit when done.
        """
    }

    private func featureFixPrompt(_ summary: String) -> String {
        """
        You are finalizing a feature built across several tasks, now all merged on this branch (the
        current directory). The integrated unit-test suite is RED — fix the code so the mode's test
        command exits 0 across the WHOLE feature. This is a cross-task integration failure: a change
        in one task likely broke another's test. Find the real cause and fix it. NEVER delete, skip,
        @Ignore, or loosen a test to dodge a real failure. Keep all tests green. Commit when done.

        Failure summary:
        \(summary)
        """
    }

    private func block(_ task: AtelierTask, _ reason: String, run: AutopilotRun, deps: Deps) async {
        logger.warning("autopilot blocked \(task.id, privacy: .public): \(reason, privacy: .public)")
        writeAutopilotReport(task: task, project: deps.project, report: run.reportByTask[task.id], outcome: "Blocked — \(reason)")
        run.taskPhases[task.id] = .blocked(reason: reason)
        // Preserve the task's just-written testState/testIntegrity by mutating the COMMITTED row
        // (the observation cache lags and would clobber e.g. .regressed back to .green).
        if var latest = await deps.store.freshTask(task.id) {
            latest.status = .blocked
            try? await deps.store.updateTask(latest)
        } else {
            try? await deps.store.updateTaskStatus(task, to: .blocked)
        }
    }

    // MARK: - TDD gate (autopilot)

    private func modeProfile(_ deps: Deps) -> ProjectProfile {
        ProjectProfile.find(id: deps.project.profileId) ?? .generic
    }

    /// Updates a task's TDD state / summary / status in one write, off a fresh copy so it never
    /// clobbers a concurrently-updated field. Pass only what should change.
    private func applyGate(_ taskId: String, deps: Deps,
                           state: AtelierTask.TestState? = nil,
                           summary: String? = nil,
                           clearSummary: Bool = false,
                           integrity: AtelierTask.TestIntegrity? = nil,
                           changeNote: String? = nil,
                           clearChangeNote: Bool = false,
                           status: AtelierTask.Status? = nil) async {
        // Read the committed row (NOT the lagging observation cache) so a prior write in this
        // pipeline isn't clobbered by a full-row re-encode from a stale base.
        guard var t = await deps.store.freshTask(taskId) else { return }
        if let state { t.testState = state }
        if clearSummary { t.testSummary = nil }
        else if let summary { t.testSummary = summary }
        if let integrity { t.testIntegrity = integrity }
        if clearChangeNote { t.testChangeNote = nil }
        else if let changeNote { t.testChangeNote = changeNote }
        if let status { t.status = status }
        try? await deps.store.updateTask(t)
    }

    /// Iterates the worker to turn red tests green, re-running the suite after each pass, capped at
    /// `maxFixPasses`. Returns true once green. Assumes the task's tests are currently red.
    private func fixRedTests(_ task: AtelierTask, worktreePath: String, run: AutopilotRun, deps: Deps) async -> Bool {
        let profile = modeProfile(deps)
        var pass = 0
        while pass < maxFixPasses && run.status == .running {
            pass += 1
            run.taskPhases[task.id] = .fixing(pass: pass)
            guard let prior = try? await deps.store.agentsForTask(task.id).first,
                  prior.sessionId?.isEmpty == false else { return false }
            let summary = deps.store.taskByID(task.id)?.testSummary ?? "Tests are failing."
            let result = await deps.spawner.iterateAndAwait(task: task,
                                                            project: deps.project,
                                                            priorAgent: prior,
                                                            message: testFixMessage(summary, taskId: task.id),
                                                            apiKey: deps.apiKey,
                                                            store: deps.store,
                                                            server: deps.server,
                                                            approvalQueue: deps.approvalQueue,
                                                            autopilot: true)
            if let result { run.costByTask[task.id] = result.state.totalCostUsd }
            if let result, result.agent.status != .completed, result.state.looksUsageLimited {
                await pauseForUsage(task, run: run, deps: deps); return false
            }
            run.taskPhases[task.id] = .testing
            let testResult = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: deps.project.path)
            await applyGate(task.id, deps: deps, state: testResult.passed ? .green : .red, summary: testResult.summaryLine)
            if testResult.passed { return true }
        }
        return false
    }

    /// Opt-in build verification before merge (OFF by default). Runs the project's verify build
    /// command in the worktree; on failure, iterates the worker to fix (bounded). Returns true to
    /// proceed (passed, or disabled / no command / worktree gone). The toolchain was preflighted at
    /// run start, so a failure here is a real build error, not missing tooling.
    private func verifyBuild(_ task: AtelierTask, worktreePath: String, run: AutopilotRun, deps: Deps) async -> Bool {
        guard deps.project.buildVerifyBeforeMerge else { return true }
        let profile = modeProfile(deps)
        guard let command = deps.project.resolvedVerifyBuildCommand(profile: profile) else { return true }
        run.taskPhases[task.id] = .buildingVerify
        var outcome = await TestRunner.runCommand(command, worktreePath: worktreePath, profile: profile, mainRepoPath: deps.project.path)
        var pass = 0
        while let o = outcome, !o.passed, pass < maxFixPasses, run.status == .running {
            pass += 1
            run.taskPhases[task.id] = .fixing(pass: pass)
            guard let prior = try? await deps.store.agentsForTask(task.id).first,
                  prior.sessionId?.isEmpty == false else { break }
            let tail = o.stderrTail.isEmpty ? o.stdoutTail : o.stderrTail
            let r = await deps.spawner.iterateAndAwait(
                task: task, project: deps.project, priorAgent: prior,
                message: buildFixMessage(command, String(tail.suffix(1500))), apiKey: deps.apiKey,
                store: deps.store, server: deps.server, approvalQueue: deps.approvalQueue, autopilot: true)
            if let r { run.costByTask[task.id] = r.state.totalCostUsd }
            if let r, r.agent.status != .completed, r.state.looksUsageLimited {
                await pauseForUsage(task, run: run, deps: deps); return false
            }
            outcome = await TestRunner.runCommand(command, worktreePath: worktreePath, profile: profile, mainRepoPath: deps.project.path)
        }
        if let o = outcome { run.buildVerifyByTask[task.id] = o }   // surface in the dossier
        return outcome?.passed ?? true   // nil = worktree gone; don't hard-fail on that
    }

    private func buildFixMessage(_ command: String, _ tail: String) -> String {
        """
        The build verification command failed: `\(command)`. Fix the build so it exits 0. Keep the
        tests green and don't weaken them. Commit when done.

        Build output (tail):
        \(tail)
        """
    }

    private func testFixMessage(_ summary: String, taskId: String) -> String {
        """
        Your tests are failing — the strict-TDD gate blocks this task until they pass. Fix the code
        so the test command exits 0. If a test asserts an OBSOLETE design you deliberately changed,
        you may update that test to assert the NEW behavior at equal-or-greater strength — and declare
        it in `.atelier/test-changes/\(taskId).md`. NEVER delete, @Ignore/skip, or loosen a test just
        to dodge a real failure; that is detected and blocks the merge. Commit when done.

        Failure summary:
        \(summary)
        """
    }

    /// Fed to the worker when the alignment reviewer found the test change doesn't serve the demand.
    private func alignmentFixMessage(_ v: AIAssistant.AlignmentVerdict, taskId: String) -> String {
        """
        A reviewer checked whether your test changes were necessary and whether the implementation
        still answers the original demand (and the broader feature). It found problems:
        \(v.rationale)

        Do this:
        \(v.fixInstructions)

        Converge on a solution that FULLY answers the demand WITHOUT weakening tests. If a test must
        change, it must assert the new behavior at equal-or-greater strength, and you must declare it
        in `.atelier/test-changes/\(taskId).md`. Keep the test suite green. Commit when done.
        """
    }

    /// The broader feature context (the "global demand"): the sibling tasks in this autopilot run,
    /// so the alignment reviewer can judge against the whole feature, not just one task.
    private func featureContext(_ run: AutopilotRun, _ deps: Deps, excluding taskId: String) -> String? {
        let titles = run.taskPhases.keys
            .filter { $0 != taskId }
            .compactMap { deps.store.taskByID($0)?.title }
            .sorted()
        guard !titles.isEmpty else { return nil }
        return "This task is part of a larger feature built in parallel. Sibling tasks:\n"
            + titles.map { "- \($0)" }.joined(separator: "\n")
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
        persistRunRecord(run)
    }

    /// Persists the run as a grouped record (integration branch + its tasks) so the
    /// Done column can show it as one entity with a combined diff + iterate/merge.
    private func persistRunRecord(_ run: AutopilotRun) {
        guard !run.integrationBranch.isEmpty, let deps = run.deps else { return }
        let tasks: [AutopilotRunRecord.TaskOutcome] = run.taskPhases.keys.compactMap { id in
            guard let t = deps.store.taskByID(id) else { return nil }
            let status: AutopilotRunRecord.TaskOutcome.Status
            var reason: String?
            switch run.taskPhases[id] {
            case .done:               status = .merged
            case .blocked(let r):     status = .blocked; reason = r
            default:                  status = .incomplete
            }
            return .init(id: id, title: t.title, status: status, reason: reason)
        }.sorted { $0.id < $1.id }
        guard !tasks.isEmpty else { return }
        let record = AutopilotRunRecord(id: run.integrationBranch,
                                        projectId: run.projectId,
                                        integrationBranch: run.integrationBranch,
                                        baseBranch: run.originalBase,
                                        startedAt: run.startedAt,
                                        finishedAt: Date(),
                                        totalCostUsd: run.totalCostUsd,
                                        tasks: tasks,
                                        deliverablePath: run.deliverablePath)
        AutopilotRunStore.append(record, projectPath: deps.project.path)
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
        scheduleAutoResume(run: run, projectId: deps.project.id)
    }

    /// Schedules ONE automatic resume after a usage-limit pause — only when we can determine the
    /// reset time (from the Claude subscription usage endpoint). We resume `resetsAt + 5 min` (a
    /// margin, since relaunching exactly on the reset minute often still trips the limit). If the
    /// reset time is unknown, or this run already used its one auto-resume, we leave it for the
    /// manual Resume button. `resetsAt` is an absolute Date (ISO-8601 with offset) — timezone-safe.
    private func scheduleAutoResume(run: AutopilotRun, projectId: String) {
        guard !run.didAutoResume else { return }
        run.didAutoResume = true
        run.autoResumeTask?.cancel()
        run.autoResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let resetsAt = await Self.nextUsageResetDate() else { return }   // unknown → manual only
            let resumeAt = resetsAt.addingTimeInterval(300)   // +5 min margin
            // Reflect the plan in the paused pill so the user knows it'll come back on its own.
            if case .paused = run.status, runs[projectId] === run {
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none   // user's local tz
                run.status = .paused("Usage limit — auto-resume around \(f.string(from: resumeAt)) (or Resume now).")
            }
            let delay = max(resumeAt.timeIntervalSinceNow, 30)   // at least a short beat
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, runs[projectId] === run, case .paused = run.status else { return }
            resume(projectId: projectId)
        }
    }

    /// Best-effort "when can we resume?" from the Claude subscription usage endpoint. Returns the
    /// LATEST reset among maxed (≥95%) windows (you can't resume until every blocking window resets),
    /// else the soonest future reset across windows, else nil (API-key users / endpoint unavailable).
    private static func nextUsageResetDate() async -> Date? {
        guard let limits = try? await UsageLimitsService.fetch() else { return nil }
        let windows = [limits.fiveHour, limits.sevenDay, limits.sevenDayOpus, limits.sevenDaySonnet].compactMap { $0 }
        let now = Date()
        let blocking = windows.filter { $0.utilization >= 95 }.compactMap { $0.resetsAt }.filter { $0 > now }
        if let latest = blocking.max() { return latest }
        return windows.compactMap { $0.resetsAt }.filter { $0 > now }.min()
    }

    private func overBudget(_ run: AutopilotRun) -> Bool {
        guard let cap = run.budgetCapUsd, cap > 0 else { return false }
        return run.totalCostUsd >= cap
    }

    private func budgetMessage(_ run: AutopilotRun) -> String {
        String(format: "Budget cap reached — $%.2f spent of $%.2f.", run.totalCostUsd, run.budgetCapUsd ?? 0)
    }

    private func fixMessage(_ findings: [ReviewFinding], taskId: String) -> String {
        let list = findings.enumerated()
            .map { "\($0.offset + 1). \($0.element.oneLine)\n   Fix: \($0.element.suggestedFix)" }
            .joined(separator: "\n")
        return """
        A reviewer found blocking issues in your work. Fix ONLY these — do not refactor anything
        else, and ignore any minor/cosmetic nits. Keep the build and tests green, and commit when done.
        If a fix legitimately changes behavior a test asserted, update that test to the new contract
        (equal-or-greater strength) and declare it in `.atelier/test-changes/\(taskId).md` — never
        weaken or skip a test to pass.

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
