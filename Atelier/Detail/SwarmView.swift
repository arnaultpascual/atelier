// SPDX-License-Identifier: MIT
import SwiftUI

/// Cross-project overview of every active (and recently finished) worker run.
/// One responsive grid card per `ActiveRun`. Clicking a card focuses that task
/// (selects its project + task), closing the swarm and opening the inspector.
struct SwarmView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var featureRunner: FeatureBuildRunner
    let onPick: (_ projectId: String, _ taskId: String) -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 14)]

    var body: some View {
        ZStack {
            Color.atelierBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                header
                if liveRuns.isEmpty && reviewRuns.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Swarm")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("\(workerCount) worker\(workerCount == 1 ? "" : "s")")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if totalCost > 0 {
                    Text(String(format: "· $%.4f", totalCost))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
                Spacer()
            }
            Text("All Claude workers currently running across your projects.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            AtelierDivider()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                // Autopilot review/conflict phases first — these aren't spawner runs,
                // so they'd otherwise be invisible while the round is being integrated.
                ForEach(reviewRuns) { entry in
                    AutopilotReviewCard(entry: entry,
                                        onTap: { onPick(entry.project.id, entry.taskId) })
                }
                ForEach(liveRuns, id: \.taskId) { entry in
                    SwarmCard(
                        run: entry.run,
                        task: entry.task,
                        project: entry.project,
                        canRelaunch: server.helperReady && !spawner.hasLiveWorker(for: entry.task.id),
                        onTap: { onPick(entry.project.id, entry.task.id) },
                        onRelaunch: {
                            spawner.start(task: entry.task,
                                          project: entry.project,
                                          apiKey: APIKeyResolver.resolve(),
                                          store: store,
                                          server: server,
                                          approvalQueue: approvalQueue)
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 76, height: 76)
                Image(systemName: "waveform.path")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.atelierAccent)
            }
            VStack(spacing: 4) {
                Text("No workers running")
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                Text("Spawn a task from any project and it will show up here\nwith live cost, status and last activity.")
                    .multilineTextAlignment(.center)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private struct Entry: Identifiable, Hashable {
        let taskId: String
        let run: ActiveRun
        let task: AtelierTask
        let project: Project
        var id: String { taskId }
        static func == (l: Entry, r: Entry) -> Bool { l.taskId == r.taskId }
        func hash(into hasher: inout Hasher) { hasher.combine(taskId) }
    }

    private var liveRuns: [Entry] {
        spawner.runs.values
            .compactMap { run -> Entry? in
                guard let task = store.taskByID(run.taskId),
                      let project = store.projectByID(task.projectId) else { return nil }
                return Entry(taskId: run.taskId, run: run, task: task, project: project)
            }
            // Non-terminal first, sorted by most recent.
            .sorted { lhs, rhs in
                let lhsLive = !lhs.run.agent.status.isTerminal
                let rhsLive = !rhs.run.agent.status.isTerminal
                if lhsLive != rhsLive { return lhsLive }
                let lhsTime = lhs.run.agent.startedAt ?? .distantPast
                let rhsTime = rhs.run.agent.startedAt ?? .distantPast
                return lhsTime > rhsTime
            }
    }

    private var totalCost: Double {
        liveRuns.reduce(0) { $0 + $1.run.state.totalCostUsd }
            + reviewRuns.reduce(0) { $0 + $1.costSoFar }
    }

    private var workerCount: Int { liveRuns.count + reviewRuns.count }

    // MARK: Autopilot review/conflict phases (not spawner runs)

    struct ReviewEntry: Identifiable {
        let taskId: String
        let task: AtelierTask
        let project: Project
        let phase: TaskPhase
        let costSoFar: Double
        var id: String { taskId }
    }

    /// Autopilot tasks currently being reviewed or having a conflict resolved by Opus.
    /// These go through `claude` one-shot (not TaskSpawner), so they don't appear in
    /// `liveRuns`. The build/fix phases already show as spawner runs, so we skip them.
    private var reviewRuns: [ReviewEntry] {
        var out: [ReviewEntry] = []
        for run in featureRunner.runs.values {
            for (taskId, phase) in run.taskPhases {
                switch phase {
                case .reviewing, .resolvingConflict:
                    guard !spawner.hasLiveWorker(for: taskId),
                          let task = store.taskByID(taskId),
                          let project = store.projectByID(task.projectId) else { continue }
                    let cost = (run.costByTask[taskId] ?? 0) + (run.reviewCostByTask[taskId] ?? 0)
                    out.append(ReviewEntry(taskId: taskId, task: task, project: project, phase: phase, costSoFar: cost))
                default:
                    continue
                }
            }
        }
        return out.sorted { $0.taskId < $1.taskId }
    }
}

// MARK: - Card

private struct SwarmCard: View {
    let run: ActiveRun
    let task: AtelierTask
    let project: Project
    let canRelaunch: Bool
    let onTap: () -> Void
    let onRelaunch: () -> Void
    @State private var hover = false

    /// A worker that stopped on an Anthropic usage/rate limit (not a real failure).
    private var isUsageLimited: Bool {
        run.agent.status.isTerminal && run.agent.status != .completed && run.state.looksUsageLimited
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusBadge
                    Spacer()
                    if isUsageLimited {
                        relaunchButton
                    }
                    if !run.agent.status.isTerminal {
                        pulse.frame(width: 8, height: 8)
                    }
                }
                Text(task.title)
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(project.name)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text("·")
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(task.id)
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                }
                lastActivityRow
                Divider().background(Color.atelierDivider.opacity(0.5))
                HStack(spacing: 10) {
                    Label(prettyModelName(run.agent.model), systemImage: "cpu")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                    if let started = run.agent.startedAt {
                        if run.agent.endedAt == nil {
                            // Live: re-render every second so the elapsed time ticks
                            // instead of only updating when other state changes.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Label(elapsed(since: started, until: nil), systemImage: "clock")
                                    .font(AtelierFont.captionMono)
                                    .foregroundStyle(Color.atelierInkSecondary)
                            }
                        } else {
                            Label(elapsed(since: started, until: run.agent.endedAt), systemImage: "clock")
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierInkSecondary)
                        }
                    }
                    Text(String(format: "$%.4f", run.state.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atelierCard(border: borderColor, borderWidth: hover ? 1.5 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var statusBadge: some View {
        let (label, color, icon) = badgeInfo
        return Label(label, systemImage: icon)
            .font(AtelierFont.eyebrow)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private var pulse: some View {
        Circle()
            .fill(Color.atelierAccent)
    }

    private var relaunchButton: some View {
        Button(action: onRelaunch) {
            Label("Relaunch", systemImage: "arrow.clockwise")
                .font(AtelierFont.eyebrow.weight(.semibold))
                .foregroundStyle(canRelaunch ? Palette.warning : Color.atelierInkSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((canRelaunch ? Palette.warning : Color.atelierInkSecondary).opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke((canRelaunch ? Palette.warning : Color.atelierInkSecondary).opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canRelaunch)
        .help(canRelaunch
              ? "Re-spawn this worker on the same task — your usage limit has likely reset."
              : "Can't relaunch now — the approval helper isn't ready or a worker is already running.")
    }

    private var badgeInfo: (String, Color, String) {
        if isUsageLimited { return ("Usage limit", Palette.warning, "pause.circle.fill") }
        switch run.agent.status {
        case .spawned: return ("Spawning", Palette.warning, "hourglass")
        case .running: return ("Running", Color.atelierAccent, "play.fill")
        case .awaitingApproval: return ("Awaiting", Palette.warning, "hand.raised")
        case .completed: return ("Completed", Palette.success, "checkmark.circle")
        case .failed: return ("Failed", Palette.error, "exclamationmark.octagon")
        case .killed: return ("Killed", Palette.error.opacity(0.8), "stop.circle")
        }
    }

    @ViewBuilder
    private var lastActivityRow: some View {
        if let last = lastActivity {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.atelierInkSecondary)
                Text(last)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Waiting for activity…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
    }

    private var lastActivity: String? {
        for event in run.state.events.reversed() {
            switch event.kind {
            case .assistant(let text, _, let toolUses):
                if let text, !text.isEmpty { return text }
                if let use = toolUses.last { return "\(use.name) · \(use.oneLineSummary)" }
            case .user(let results):
                if let first = results.first {
                    return "→ " + first.textSummary
                }
            case .result(let subtype, _, _, let isError):
                return isError ? "Failed: \(subtype ?? "error")" : "Result: \(subtype ?? "success")"
            default:
                continue
            }
        }
        return nil
    }

    private var borderColor: Color {
        if !run.agent.status.isTerminal { return Color.atelierAccent.opacity(0.5) }
        return Color.atelierDivider.opacity(0.6)
    }

    private func prettyModelName(_ raw: String) -> String {
        if let m = ModelRouter.Model(rawValue: raw) { return m.displayName }
        return raw
    }

    private func elapsed(since start: Date, until end: Date?) -> String {
        let target = end ?? Date()
        let secs = Int(target.timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }
}

// MARK: - Autopilot review-phase card

/// A task being reviewed (or having a conflict resolved) by Opus during an
/// autopilot round. Not backed by a TaskSpawner run, so it gets its own light card.
private struct AutopilotReviewCard: View {
    let entry: SwarmView.ReviewEntry
    let onTap: () -> Void
    @State private var hover = false

    private var phaseLabel: String {
        if case .resolvingConflict = entry.phase { return "Resolving conflict" }
        return "Opus reviewing"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierAccent)
                    Text(phaseLabel)
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                Text(entry.task.title)
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(entry.project.name)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text("·").foregroundStyle(Color.atelierInkSecondary)
                    Text(entry.taskId)
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                }
                Divider().background(Color.atelierDivider.opacity(0.5))
                HStack(spacing: 10) {
                    Label("Opus 4.7", systemImage: "cpu")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                    if entry.costSoFar > 0 {
                        Text(String(format: "$%.4f", entry.costSoFar))
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Color.atelierAccent)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atelierCard(border: Color.atelierAccent.opacity(0.4), borderWidth: hover ? 1.5 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
