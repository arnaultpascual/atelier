// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit

/// 5-column kanban for the selected project's tasks: quick-add, drag-and-drop between
/// columns to change status, spawning workers, and per-round autopilot.
struct BacklogPane: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var featureRunner: FeatureBuildRunner
    let selectedProjectID: String?
    @Binding var selectedTaskID: String?

    @State private var settingsProject: Project?
    @State private var settingsToPermissions = false
    @State private var settingsToClaudeMd = false
    @State private var fillKanbanProject: Project?
    @State private var planBatchProject: Project?

    var body: some View {
        ZStack {
            Color.atelierBackground.ignoresSafeArea()
            content
        }
        .sheet(item: $settingsProject) { p in
            ProjectSettingsSheet(store: store,
                                 project: p,
                                 openToPermissions: settingsToPermissions,
                                 openToClaudeMd: settingsToClaudeMd,
                                 onClose: { settingsProject = nil })
        }
        .sheet(item: $fillKanbanProject) { p in
            FillKanbanSheet(store: store,
                            project: p,
                            onClose: { fillKanbanProject = nil })
        }
        .sheet(item: $planBatchProject) { p in
            PlanBatchView(store: store,
                          spawner: spawner,
                          server: server,
                          approvalQueue: approvalQueue,
                          featureRunner: featureRunner,
                          project: p,
                          onClose: { planBatchProject = nil })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let project = selectedProject {
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                ProjectHeader(project: project,
                              taskCount: store.tasks(in: project.id).count,
                              autopilotRun: featureRunner.run(for: project.id),
                              canStartAutopilot: canStartAutopilot(project),
                              autopilotRounds: autopilotRounds(project),
                              onStartAutopilot: { batches, cap in
                                  featureRunner.start(project: project, batches: batches, budgetCapUsd: cap,
                                                      store: store, spawner: spawner, server: server,
                                                      approvalQueue: approvalQueue)
                              },
                              onStopAutopilot: { force in featureRunner.stop(projectId: project.id, force: force) },
                              onResumeAutopilot: { featureRunner.resume(projectId: project.id) },
                              onOpenApprovalSettings: { settingsToPermissions = true; settingsToClaudeMd = false; settingsProject = project },
                              onClearAutopilot: { featureRunner.clearRun(projectId: project.id) },
                              onRefresh: { _ = try? await store.importTasksFromDisk(project: project) },
                              onSettings: { settingsToPermissions = false; settingsToClaudeMd = false; settingsProject = project },
                              onOpenClaudeMd: { settingsToPermissions = false; settingsToClaudeMd = true; settingsProject = project },
                              onFillKanban: { fillKanbanProject = project },
                              onPlanBatch: { planBatchProject = project })
                KanbanBoard(store: store,
                            spawner: spawner,
                            server: server,
                            approvalQueue: approvalQueue,
                            featureRunner: featureRunner,
                            project: project,
                            selectedTaskID: $selectedTaskID)
            }
        } else if store.workspaces.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                OnboardingPanel()
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                PickProjectPanel()
                Spacer()
            }
        }
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: 16)
    }

    private var selectedProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return store.projectByID(id)
    }

    /// Autopilot can start when the approval helper is ready and at least one To Do task is
    /// runnable now (its dependencies are all Done).
    private func canStartAutopilot(_ project: Project) -> Bool {
        guard server.helperReady else { return false }
        let todo = store.tasks(in: project.id, status: .toDo)
        return !ExecutionPlanner.runnableNow(tasks: todo, allTasks: store.tasks(in: project.id)).isEmpty
    }

    /// Execution rounds previewed in the autopilot start-popover (so you see what it will build).
    private func autopilotRounds(_ project: Project) -> [AutopilotRoundPreview] {
        let all = store.tasks(in: project.id)
        let todo = all.filter { $0.status == .toDo }
        return ExecutionPlanner.waves(tasks: todo, allTasks: all).map {
            AutopilotRoundPreview(round: $0.round, titles: $0.tasks.map(\.title))
        }
    }
}

// MARK: - Project header

private struct ProjectHeader: View {
    let project: Project
    let taskCount: Int
    let autopilotRun: AutopilotRun?
    let canStartAutopilot: Bool
    let autopilotRounds: [AutopilotRoundPreview]
    let onStartAutopilot: (Int, Double?) -> Void
    let onStopAutopilot: (Bool) -> Void
    let onResumeAutopilot: () -> Void
    let onOpenApprovalSettings: () -> Void
    let onClearAutopilot: () -> Void
    let onRefresh: () async -> Void
    let onSettings: () -> Void
    let onOpenClaudeMd: () -> Void
    let onFillKanban: () -> Void
    let onPlanBatch: () -> Void
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(project.name)
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                if let profile = ProjectProfile.find(id: project.profileId) {
                    HStack(spacing: 4) {
                        Image(systemName: profile.iconSystemName)
                            .font(.system(size: 10))
                        Text(profile.name)
                            .font(AtelierFont.eyebrow)
                    }
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                    .help(profile.description)
                }
                Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                claudeMdPill
                if let budget = project.budgetUsdMonthly, budget > 0 {
                    budgetPill(budget: budget)
                }
                Spacer()
                AutopilotControl(run: autopilotRun,
                                 canStart: canStartAutopilot,
                                 rounds: autopilotRounds,
                                 onStart: onStartAutopilot,
                                 onStop: onStopAutopilot,
                                 onResume: onResumeAutopilot,
                                 onOpenApprovalSettings: onOpenApprovalSettings,
                                 onClear: onClearAutopilot)
                Button(action: onPlanBatch) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 10))
                        Text("Plan")
                            .font(AtelierFont.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Organize tasks into autopilot rounds and launch — drag tasks between rounds to set dependencies.")
                Button(action: onFillKanban) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                        Text("Fill kanban")
                            .font(AtelierFont.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Decompose a brief into kanban tasks with Opus 4.7.")
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Project settings — name, profile, default model, monthly budget")
                Button {
                    refreshing = true
                    Task { await onRefresh(); refreshing = false }
                } label: {
                    Group {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.atelierInkSecondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .help("Re-scan `backlog/tasks/*.md` from disk")
            }
            Text((project.path as NSString).abbreviatingWithTildeInPath)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, AtelierSpacing.gutter)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atelierDivider.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var claudeMdPill: some View {
        let exists = FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: project.path).appendingPathComponent("CLAUDE.md").path
        )
        Button(action: onOpenClaudeMd) {
            HStack(spacing: 4) {
                Image(systemName: exists ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 9))
                Text(exists ? "CLAUDE.md" : "no CLAUDE.md")
                    .font(AtelierFont.eyebrow)
            }
            .foregroundStyle(exists ? Color.atelierInk : Color.atelierInkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (exists ? Color.atelierSurface : Color.clear),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    exists ? Color.atelierDivider : Color.atelierDivider.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: exists ? [] : [3, 3])
                )
            )
        }
        .buttonStyle(.plain)
        .help(exists
              ? "CLAUDE.md present — click to view or regenerate via Project settings."
              : "No CLAUDE.md yet — click to draft one with Haiku.")
    }

    @ViewBuilder
    private func budgetPill(budget: Double) -> some View {
        // For now we only know what Atelier itself has spent on this
        // project; a richer "month-to-date" lives in the dashboard. The
        // pill is informational — it surfaces the budget so the user
        // remembers the cap exists.
        HStack(spacing: 4) {
            Image(systemName: "creditcard")
                .font(.system(size: 9))
            Text(String(format: "$%.0f / mo", budget))
                .font(AtelierFont.eyebrow)
        }
        .foregroundStyle(Color.atelierInkSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Color.atelierSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        .help("Monthly budget cap (informational). Edit in project settings.")
    }
}

// MARK: - Kanban board

private struct KanbanBoard: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var featureRunner: FeatureBuildRunner
    let project: Project
    @Binding var selectedTaskID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(AtelierTask.Status.kanbanOrder, id: \.self) { status in
                    KanbanColumn(
                        store: store,
                        spawner: spawner,
                        server: server,
                        approvalQueue: approvalQueue,
                        featureRunner: featureRunner,
                        project: project,
                        status: status,
                        tasks: store.tasks(in: project.id, status: status),
                        selectedTaskID: $selectedTaskID
                    )
                }
            }
            .padding(.horizontal, AtelierSpacing.gutter)
            .padding(.vertical, 18)
        }
    }
}

private struct KanbanColumn: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var featureRunner: FeatureBuildRunner
    let project: Project
    let status: AtelierTask.Status
    let tasks: [AtelierTask]
    @Binding var selectedTaskID: String?
    @State private var isDropTargeted = false
    @State private var createError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if status == .toDo {
                QuickAddRow { title in
                    Task {
                        do {
                            createError = nil
                            let t = try await store.createTask(in: project, title: title)
                            selectedTaskID = t.id
                        } catch {
                            createError = error.localizedDescription
                        }
                    }
                }
                if let createError {
                    CalloutBanner(.danger, "Couldn't create task: \(createError)")
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if status == .toDo && executionWaves().count > 1 {
                        // Keep the decomposer's round/batch structure visible: group
                        // To Do by execution wave (derived live from dependsOn + done
                        // status), so you see what can run in parallel NOW (round 1)
                        // vs what's blocked behind it — and can spawn a whole round.
                        ForEach(executionWaves(), id: \.round) { wave in
                            roundHeader(round: wave.round, tasks: wave.tasks)
                            ForEach(wave.tasks) { card($0) }
                        }
                    } else {
                        ForEach(tasks) { card($0) }
                        if tasks.isEmpty {
                            EmptyColumnHint(status: status)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: 280)
        .padding(12)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isDropTargeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.5),
                    lineWidth: isDropTargeted ? 1.5 : 1))
        .dropDestination(for: String.self) { ids, _ in
            var moved = false
            for id in ids {
                guard let t = store.taskByID(id), t.status != status else { continue }
                Task { try? await store.updateTaskStatus(t, to: status) }
                moved = true
            }
            return moved
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private func card(_ task: AtelierTask) -> some View {
        TaskCard(
            task: task,
            run: spawner.activeRun(for: task.id),
            autopilotPhase: featureRunner.run(for: project.id)?.taskPhases[task.id],
            isSelected: selectedTaskID == task.id,
            canSpawn: canSpawn(task: task),
            onTap: { selectedTaskID = task.id },
            onSpawn: { spawn(task: task) }
        )
    }

    @ViewBuilder
    private func roundHeader(round: Int, tasks wave: [AtelierTask]) -> some View {
        let runnable = round == 1   // round 1 = every dependency already Done
        let spawnable = wave.filter { canSpawn(task: $0) }.count
        HStack(spacing: 6) {
            Text("ROUND \(round)")
                .font(AtelierFont.eyebrow.weight(.semibold))
                .foregroundStyle(runnable ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.55))
            Text(runnable ? "\(wave.count) in parallel" : "blocked")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary.opacity(runnable ? 0.9 : 0.55))
            Spacer(minLength: 4)
            if featureRunner.isActive(projectId: project.id) {
                Text("autopilot")
                    .font(AtelierFont.eyebrow.weight(.medium))
                    .foregroundStyle(Color.atelierAccent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
            } else if runnable && spawnable > 0 {
                Button {
                    for t in wave where canSpawn(task: t) { spawn(task: t) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("Spawn \(spawnable)").font(AtelierFont.eyebrow.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierAccent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Spawn all \(spawnable) runnable task\(spawnable == 1 ? "" : "s") in this round in parallel")
            }
        }
        .padding(.top, round == 1 ? 2 : 8)
    }

    /// Groups the To Do tasks into execution waves from `dependsOn`, using the real
    /// done-status of dependencies. Delegates to `ExecutionPlanner` so the autopilot and
    /// this board always agree on what's runnable. Recomputed live, so finishing one round
    /// unlocks the next.
    private func executionWaves() -> [(round: Int, tasks: [AtelierTask])] {
        ExecutionPlanner.waves(tasks: tasks, allTasks: store.tasks(in: project.id))
    }

    private func canSpawn(task: AtelierTask) -> Bool {
        // The hover affordance is intentionally restricted to the To Do
        // column — spawning from In Progress / Review / Done would conflict
        // with the work already in those states.
        guard status == .toDo else { return false }
        guard server.helperReady else { return false }
        guard !spawner.hasLiveWorker(for: task.id) else { return false }
        guard FileManager.default.fileExists(atPath: project.path) else { return false }
        // Enforce the dependency graph: a task can't run until all its
        // dependencies are Done (prevents spawning a blocked round-2 task).
        if !task.dependsOn.isEmpty {
            let done = Set(store.tasks(in: project.id).filter { $0.status == .done }.map(\.id))
            if !task.dependsOn.allSatisfy({ done.contains($0) }) { return false }
        }
        return true
    }

    private func spawn(task: AtelierTask) {
        guard canSpawn(task: task) else { return }
        spawner.start(
            task: task,
            project: project,
            apiKey: APIKeyResolver.resolve(),
            store: store,
            server: server,
            approvalQueue: approvalQueue
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(status.displayName.uppercased())
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInk)
            Text("\(tasks.count)")
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
        }
    }

    private var accent: Color {
        switch status {
        case .toDo: return Color.atelierInkSecondary.opacity(0.55)
        case .inProgress: return Color.atelierAccent
        case .review: return Palette.warning
        case .done: return Palette.success
        case .blocked: return Palette.error
        }
    }
}

private struct EmptyColumnHint: View {
    let status: AtelierTask.Status

    var body: some View {
        Text(hint)
            .font(AtelierFont.caption)
            .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hint: String {
        switch status {
        case .inProgress: return "Tasks spawn here when a worker starts."
        case .review: return "Move tasks here when the worker reports success."
        case .done: return "Final resting place after merge."
        case .blocked: return "Stalled tasks — track why in the detail pane."
        case .toDo: return "No tasks yet — type above, or use Fill kanban to decompose a brief."
        }
    }
}

// MARK: - Task card

private struct TaskCard: View {
    let task: AtelierTask
    let run: ActiveRun?
    let autopilotPhase: TaskPhase?
    let isSelected: Bool
    let canSpawn: Bool
    let onTap: () -> Void
    let onSpawn: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 0) {
                if run != nil {
                    Rectangle()
                        .fill(agentAccent)
                        .frame(width: 3)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(task.title)
                            .font(AtelierFont.callout)
                            .foregroundStyle(Color.atelierInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let run, !run.agent.status.isTerminal {
                            statusPulse
                        }
                    }

                    HStack(spacing: 6) {
                        Text(task.id)
                            .font(AtelierFont.eyebrow)
                            .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                        if let p = task.priority {
                            PriorityPill(priority: p)
                        }
                        if !task.dependsOn.isEmpty {
                            DependencyChip(count: task.dependsOn.count)
                        }
                        if let phase = autopilotPhase {
                            AutopilotPhaseChip(phase: phase)
                        }
                        Spacer(minLength: 0)
                        if let run, run.state.totalCostUsd > 0 {
                            Text(String(format: "$%.4f", run.state.totalCostUsd))
                                .font(AtelierFont.captionMono.weight(.semibold))
                                .foregroundStyle(agentAccent)
                        } else if let m = task.workerModel {
                            Text(modelShortName(m))
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierInkSecondary)
                        }
                    }

                    if !task.labels.isEmpty {
                        LabelsRow(labels: task.labels)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .atelierCard(border: borderColor, borderWidth: 1, selected: isSelected)
        .overlay(alignment: .topTrailing) {
            if canSpawn && hover {
                spawnButton
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .draggable(task.id)
    }

    private var spawnButton: some View {
        Button(action: onSpawn) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Spawn")
                    .font(AtelierFont.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.atelierAccent, in: Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("Spawn a claude worker on this task in its own worktree.")
    }

    private var statusPulse: some View {
        Circle()
            .fill(agentAccent)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(agentAccent.opacity(0.35), lineWidth: 4)
                    .scaleEffect(1.5)
                    .opacity(0.0)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false), value: UUID())
            )
    }

    private var agentAccent: Color {
        guard let run else { return .clear }
        switch run.agent.status {
        case .spawned, .running: return Color.atelierAccent
        case .awaitingApproval: return Palette.warning
        case .completed: return Palette.success
        case .failed: return Palette.error
        case .killed: return Palette.error.opacity(0.7)
        }
    }

    private var borderColor: Color {
        // Selection is shown via a soft accent fill (see `.atelierCard(selected:)`), and a
        // running worker via the left strip — so the border only carries hover emphasis.
        if hover { return Color.atelierDivider }
        return Color.atelierDivider.opacity(0.5)
    }

    private func modelShortName(_ raw: String) -> String {
        // claude-sonnet-4-6 → Sonnet 4.6
        let parts = raw.split(separator: "-")
        guard parts.count >= 4, parts[0] == "claude" else { return raw }
        let family = parts[1].capitalized
        let version = "\(parts[2]).\(parts[3])"
        return "\(family) \(version)"
    }
}

struct PriorityPill: View {
    let priority: AtelierTask.Priority
    var body: some View {
        Text(priority.displayName.lowercased())
            .font(AtelierFont.eyebrow)
            .foregroundStyle(textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }
    private var bg: Color {
        switch priority {
        case .critical: return Palette.error.opacity(0.15)
        case .high: return Color.atelierAccent.opacity(0.15)
        case .medium: return Palette.warning.opacity(0.15)
        case .low: return Color.atelierInkSecondary.opacity(0.12)
        }
    }
    private var textColor: Color {
        switch priority {
        case .critical: return Palette.error
        case .high: return Color.atelierAccent
        case .medium: return Palette.warning
        case .low: return Color.atelierInkSecondary
        }
    }
}

// MARK: - Autopilot control

/// One execution round shown in the start-popover preview (the tasks that build in parallel).
struct AutopilotRoundPreview: Identifiable {
    let round: Int
    let titles: [String]
    var id: Int { round }
}

/// Header control: a popover to start "Build entire feature" (rounds preview + how many batches +
/// budget cap + safety warning), or a live pill (round/phase/cost + Stop) while a run is active.
private struct AutopilotControl: View {
    let run: AutopilotRun?
    let canStart: Bool
    let rounds: [AutopilotRoundPreview]
    let onStart: (Int, Double?) -> Void
    let onStop: (Bool) -> Void
    let onResume: () -> Void
    let onOpenApprovalSettings: () -> Void
    let onClear: () -> Void

    @State private var showConfig = false
    @State private var confirmDismiss = false
    @State private var showSummary = false

    var body: some View {
        if let run {
            switch run.status {
            case .running, .stopping:
                runningPill(run)
            case .paused(let reason):
                pausedPill(reason)
            case .finished:
                finishedPill(run)
            case .failed(let msg):
                resultPill(icon: "exclamationmark.triangle.fill", color: Palette.error, text: msg)
            }
        } else {
            startButton
        }
    }

    /// Usage/rate limit hit — the run is parked. Resume continues on the same feature branch.
    private func pausedPill(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.warning)
            Text("Paused · usage limit")
                .font(AtelierFont.caption.weight(.medium))
                .foregroundStyle(Palette.warning)
                .lineLimit(1)
                .help(reason)
            Button { onResume() } label: {
                Text("Resume").font(AtelierFont.caption.weight(.medium))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Continue on the same feature branch — re-integrates finished tasks, then builds the rest.")
            Button { confirmDismiss = true } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss without resuming.")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Palette.warning.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Palette.warning.opacity(0.3), lineWidth: 1))
        .confirmationDialog("Discard this paused autopilot run?", isPresented: $confirmDismiss, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { onClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The feature branch stays on disk, but you'll lose the in-app Resume handle to it.")
        }
    }

    private func resultPill(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(text)
                .font(AtelierFont.caption.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .help(text)
            Button { onClear() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }

    /// Finished run — names the integration branch and offers copy actions so it isn't a dead string.
    private func finishedPill(_ run: AutopilotRun) -> some View {
        let branch = run.integrationBranch
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.success)
            Text(branch.isEmpty ? "Autopilot finished" : "Done → \(branch)")
                .font(AtelierFont.caption.weight(.medium))
                .foregroundStyle(Palette.success)
                .lineLimit(1)
                .help(branch.isEmpty ? "Autopilot finished." : "Built onto \(branch). Review it, then merge into your branch.")
            Button { showSummary.toggle() } label: {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSummary, arrowEdge: .bottom) { summaryPopover(run) }
            .help("Run summary — merged / blocked / cost")
            if !branch.isEmpty {
                Menu {
                    Button("Copy branch name") { copyToPasteboard(branch) }
                    Button("Copy merge command") { copyToPasteboard("git merge --no-ff \(branch)") }
                    Button("Copy checkout command") { copyToPasteboard("git checkout \(branch)") }
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Copy the branch name or a git command to integrate it")
            }
            Button { onClear() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Palette.success.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Palette.success.opacity(0.3), lineWidth: 1))
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func runSummary(_ run: AutopilotRun) -> (done: Int, blocked: [(id: String, reason: String)]) {
        var done = 0
        var blocked: [(id: String, reason: String)] = []
        for (taskId, phase) in run.taskPhases.sorted(by: { $0.key < $1.key }) {
            switch phase {
            case .done: done += 1
            case .blocked(let reason): blocked.append((taskId, reason))
            default: break
            }
        }
        return (done, blocked)
    }

    private func summaryPopover(_ run: AutopilotRun) -> some View {
        let s = runSummary(run)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Autopilot run").font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
            HStack(spacing: 10) {
                Label("\(s.done) merged", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
                if !s.blocked.isEmpty {
                    Label("\(s.blocked.count) blocked", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.error)
                }
                Spacer()
                if run.totalCostUsd > 0 {
                    Text(String(format: "$%.2f", run.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
            }
            .font(AtelierFont.caption)
            if !run.integrationBranch.isEmpty {
                Text(run.integrationBranch)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .textSelection(.enabled)
            }
            if !s.blocked.isEmpty {
                AtelierDivider()
                SectionLabel("BLOCKED")
                ForEach(s.blocked, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.id)
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Color.atelierInk)
                        Text(item.reason)
                            .font(AtelierFont.caption)
                            .foregroundStyle(Color.atelierInkSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var startButton: some View {
        Button { showConfig = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "infinity").font(.system(size: 10))
                Text("Autopilot").font(AtelierFont.caption.weight(.medium))
            }
            .foregroundStyle(canStart ? Color.atelierAccent : Color.atelierInkSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.atelierAccentSoft.opacity(canStart ? 0.5 : 0.25), in: Capsule())
            .overlay(Capsule().stroke(Color.atelierAccent.opacity(canStart ? 0.4 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .help(canStart
              ? "Build whole rounds autonomously: build → review → fix → merge, hands-off."
              : "Needs the approval helper ready and at least one runnable To Do task.")
        .popover(isPresented: $showConfig, arrowEdge: .bottom) {
            AutopilotConfigPopover(rounds: rounds,
                                   canStart: canStart,
                                   onStart: onStart,
                                   onOpenApprovalSettings: onOpenApprovalSettings,
                                   dismiss: { showConfig = false })
        }
    }

    private func runningPill(_ run: AutopilotRun) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("ROUND \(run.currentRound)/\(run.batchesRequested)")
                .font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierAccent)
            Text(phaseSummary(run)).font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
            if run.totalCostUsd > 0 {
                Text(String(format: "$%.2f", run.totalCostUsd))
                    .font(AtelierFont.captionMono.weight(.semibold)).foregroundStyle(Color.atelierAccent)
            }
            Menu {
                Button("Force stop — kill running workers now", role: .destructive) { onStop(true) }
            } label: {
                Text("Stop").font(AtelierFont.caption.weight(.medium))
            } primaryAction: {
                onStop(false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Stop: no new spawns, in-flight workers finish. Use the ⌄ menu to force-stop (kill running workers now).")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.atelierAccentSoft.opacity(0.4), in: Capsule())
    }

    private func phaseSummary(_ run: AutopilotRun) -> String {
        let phases = Array(run.taskPhases.values)
        func count(_ pred: (TaskPhase) -> Bool) -> Int { phases.filter(pred).count }
        let building = count { if case .building = $0 { return true }; return false }
        let reviewing = count { if case .reviewing = $0 { return true }; if case .fixing = $0 { return true }; return false }
        let merging = count { if case .merging = $0 { return true }; if case .resolvingConflict = $0 { return true }; return false }
        var parts: [String] = []
        if building > 0 { parts.append("building \(building)") }
        if reviewing > 0 { parts.append("reviewing \(reviewing)") }
        if merging > 0 { parts.append("merging \(merging)") }
        if run.status == .stopping { parts.append("stopping…") }
        return parts.isEmpty ? "working…" : parts.joined(separator: " · ")
    }
}

/// The autopilot start-popover. Extracted into its own view so `batches`/`budgetText` initialise
/// from the current rounds in `init` — a child view is created fresh each time the popover opens,
/// so the batch count reliably defaults to "all rounds" without depending on appear/onChange timing.
private struct AutopilotConfigPopover: View {
    let rounds: [AutopilotRoundPreview]
    let canStart: Bool
    let onStart: (Int, Double?) -> Void
    let onOpenApprovalSettings: () -> Void
    let dismiss: () -> Void

    @State private var batches: Int
    @State private var budgetText = ""
    @State private var confirmStart = false

    init(rounds: [AutopilotRoundPreview],
         canStart: Bool,
         onStart: @escaping (Int, Double?) -> Void,
         onOpenApprovalSettings: @escaping () -> Void,
         dismiss: @escaping () -> Void) {
        self.rounds = rounds
        self.canStart = canStart
        self.onStart = onStart
        self.onOpenApprovalSettings = onOpenApprovalSettings
        self.dismiss = dismiss
        _batches = State(initialValue: max(1, rounds.count))   // default: build ALL rounds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build entire feature")
                .font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)

            Stepper(value: $batches, in: 1...max(1, rounds.count)) {
                Text("Build \(batches) of \(rounds.count) round\(rounds.count == 1 ? "" : "s")")
                    .font(AtelierFont.caption)
            }

            if rounds.isEmpty {
                Text("No runnable tasks yet — add To Do tasks first.")
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rounds) { roundPreview($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Text("Rounds run top-to-bottom; tasks within a round build in parallel. The order comes from each task's dependencies — open a task to change what it waits on.")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary).lineSpacing(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("STOP IF SPEND EXCEEDS (USD)")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                TextField("optional — e.g. 10.00", text: $budgetText).textFieldStyle(.roundedBorder)
            }
            CalloutBanner(.warning, "Runs unattended: agents build, fix and auto-merge into a fresh atelier/autopilot-* branch (your current branch is untouched, nothing is pushed), with tool approvals auto-accepted except your explicit deny rules.")
            Button("Manage approval rules…") {
                dismiss()
                onOpenApprovalSettings()
            }
            .buttonStyle(.link)
            .font(AtelierFont.caption)
            .help("Autopilot auto-accepts every tool call except the deny rules you set here.")
            HStack {
                Spacer()
                Button("Start") { confirmStart = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .padding(16)
        .frame(width: 360)
        .confirmationDialog("Start unsupervised autopilot?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start \(batches) batch\(batches == 1 ? "" : "es")", role: .destructive) {
                let cap = Double(budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
                onStart(batches, (cap ?? 0) > 0 ? cap : nil)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Autopilot builds, reviews, fixes and auto-merges \(batches) round\(batches == 1 ? "" : "s") onto a throwaway atelier/autopilot-* branch — unattended, with tool approvals auto-accepted except your explicit deny rules.")
        }
    }

    /// Rounds beyond the chosen batch count are dimmed (greyed) and tagged "· not this run".
    private func roundPreview(_ r: AutopilotRoundPreview) -> some View {
        let included = r.round <= batches
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("ROUND \(r.round)")
                    .font(AtelierFont.eyebrow.weight(.semibold))
                    .foregroundStyle(included ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.5))
                Text(r.titles.count > 1 ? "\(r.titles.count) in parallel" : "1 task")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(included ? 0.9 : 0.4))
                if !included {
                    Text("· not this run")
                        .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.4))
                }
            }
            ForEach(r.titles, id: \.self) { title in
                Text("•  \(title)")
                    .font(AtelierFont.caption)
                    .foregroundStyle(included ? Color.atelierInk : Color.atelierInkSecondary.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small per-card chip showing a task's current autopilot phase.
private struct AutopilotPhaseChip: View {
    let phase: TaskPhase
    var body: some View {
        Text(label)
            .font(AtelierFont.eyebrow)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
    private var label: String {
        switch phase {
        case .queued: return "queued"
        case .building: return "building"
        case .reviewing: return "reviewing"
        case .fixing(let p): return "fixing \(p)"
        case .merging: return "merging"
        case .resolvingConflict: return "conflict"
        case .done: return "merged"
        case .blocked: return "blocked"
        }
    }
    private var color: Color {
        switch phase {
        case .queued: return Color.atelierInkSecondary
        case .building, .reviewing, .fixing, .merging: return Color.atelierAccent
        case .resolvingConflict: return Palette.warning
        case .done: return Palette.success
        case .blocked: return Palette.error
        }
    }
}

private struct LabelsRow: View {
    let labels: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(4), id: \.self) { l in
                Text(l)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
            }
            if labels.count > 4 {
                Text("+\(labels.count - 4)")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
    }
}

// MARK: - Quick add

private struct QuickAddRow: View {
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Color.atelierAccent : Color.atelierInkSecondary)
            TextField("Add a task and press Return", text: $text)
                .textFieldStyle(.plain)
                .font(AtelierFont.callout)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(focused ? Color.atelierAccentSoft.opacity(0.4) : Color.atelierBackground.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.atelierAccent.opacity(0.6) : Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        text = ""
    }
}

// MARK: - Onboarding & pick-project (re-used from slice 1.1 placeholders)

private struct OnboardingPanel: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Atelier")
                        .font(AtelierFont.display)
                        .foregroundStyle(Color.atelierInk)
                    Text("A native macOS studio for orchestrating parallel Claude Code workers — each in its own git worktree, gated by human-in-the-loop approvals.")
                        .font(AtelierFont.body)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    StepRow(number: "01", title: "Create a workspace",
                            body: "A workspace groups projects by client or context. From the sidebar, hit New workspace.")
                    StepRow(number: "02", title: "Add a project",
                            body: "Point Atelier at a git repository. We scaffold `backlog/`, `.atelier/` and extend `.gitignore`.")
                    StepRow(number: "03", title: "Capture tasks",
                            body: "In the To Do column, type a title and press Return — Atelier writes `backlog/tasks/<id>-<slug>.md` for you.")
                    StepRow(number: "04", title: "Spawn a worker",
                            body: "Open a task and hit Spawn — its worker runs in an isolated git worktree, so parallel workers never collide.")
                }

                AtelierDivider().frame(maxWidth: 560)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Two ways to run")
                        .font(AtelierFont.subtitle)
                        .foregroundStyle(Color.atelierInk)
                    ModeRow(icon: "hand.raised.fill",
                            title: "Human-in-the-loop",
                            detail: "Every file write, command and search pauses for your approval in the Approvals inbox — you sign off on each step.")
                    ModeRow(icon: "infinity",
                            title: "Autopilot",
                            detail: "Hands-off: Atelier builds a whole round in parallel, has Opus review each worktree, and merges only what passes — pausing on anything risky.")
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 36)
        }
    }
}

private struct PickProjectPanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Backlog")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Text("Pick a project")
                .font(AtelierFont.title)
                .foregroundStyle(Color.atelierInk)
            Text("Select a project in the sidebar to see its backlog here.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }
}

private struct StepRow: View {
    let number: String
    let title: String
    let detail: String
    var muted: Bool = false

    init(number: String, title: String, body: String, muted: Bool = false) {
        self.number = number
        self.title = title
        self.detail = body
        self.muted = muted
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(AtelierFont.eyebrow)
                .foregroundStyle(muted ? Color.atelierInkSecondary : Color.atelierAccent)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One of the two run modes shown at the foot of the welcome panel.
private struct ModeRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.atelierAccent)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
