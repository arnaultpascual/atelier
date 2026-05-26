// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Live agent view shown inside the inspector when a task has an active or recently
/// finished worker. Replaces `TaskDetailView` while `runs[task.id]` is present in
/// the `TaskSpawner`.
struct TaskAgentView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    let task: AtelierTask
    let run: ActiveRun
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .overlay(alignment: .bottom) {
                    AtelierDivider()
                }

            worktreeRow
                .padding(.horizontal, 36)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    AtelierDivider()
                }

            EventTimeline(state: run.state, hint: run.statusHint)
                .frame(maxHeight: .infinity)

            if run.agent.status == .failed && !run.state.stderrLines.isEmpty {
                stderrPane
                    .padding(.horizontal, 36)
                    .padding(.vertical, 10)
                    .background(Color.atelierBackground)
                    .overlay(alignment: .top) {
                        AtelierDivider()
                    }
            }

            footer
                .padding(.horizontal, 36)
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    AtelierDivider()
                }
                .background(Color.atelierBackground)
        }
        .background(Color.atelierBackground)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.id)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                statusBadge
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close detail (worker keeps running).")
            }
            Text(task.title)
                .font(AtelierFont.title)
                .foregroundStyle(Color.atelierInk)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                modelChip
                if let started = run.agent.startedAt {
                    Label(elapsed(since: started),
                          systemImage: "clock")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                if !run.state.events.isEmpty {
                    Label("\(run.state.events.count) events",
                          systemImage: "list.bullet")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer(minLength: 0)
            }
        }
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

    private var modelChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu").font(.system(size: 9))
            Text(prettyModelName(run.agent.model))
                .font(AtelierFont.captionMono)
        }
        .foregroundStyle(Color.atelierInkSecondary)
    }

    private var badgeInfo: (String, Color, String) {
        switch run.agent.status {
        case .spawned: return ("Spawning", Palette.warning, "hourglass")
        case .running: return ("Running", Color.atelierAccent, "play.fill")
        case .awaitingApproval: return ("Awaiting", Palette.warning, "hand.raised")
        case .completed: return ("Completed", Palette.success, "checkmark.circle")
        case .failed: return ("Failed", Palette.error, "exclamationmark.octagon")
        case .killed: return ("Killed", Palette.error.opacity(0.8), "stop.circle")
        }
    }

    // MARK: Worktree

    private var worktreeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(Color.atelierInkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.agent.branch.isEmpty ? "(no branch)" : run.agent.branch)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInk)
                if !run.agent.worktreePath.isEmpty {
                    Text((run.agent.worktreePath as NSString).abbreviatingWithTildeInPath)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if !run.agent.worktreePath.isEmpty {
                Button(action: revealWorktree) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text("Reveal").font(AtelierFont.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Open the worktree folder in Finder")
            }
        }
    }

    private func revealWorktree() {
        guard !run.agent.worktreePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.agent.worktreePath)])
    }

    private var stderrPane: some View {
        DisclosureGroup {
            ScrollView(.vertical) {
                Text(run.state.stderrLines.suffix(80).joined(separator: "\n"))
                    .font(AtelierFont.captionMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            }
            .frame(maxHeight: 200)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble").font(.system(size: 10))
                Text("worker stderr — \(run.state.stderrLines.count) line\(run.state.stderrLines.count == 1 ? "" : "s")")
                    .font(AtelierFont.caption.weight(.semibold))
                Spacer()
                if let err = run.state.lastErrorMessage {
                    Text(err).font(AtelierFont.caption).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(Palette.error.opacity(0.85))
                }
            }
            .foregroundStyle(Palette.error)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Cost")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(String(format: "$%.4f", run.state.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
                Text("in \(run.state.inputTokens) · out \(run.state.outputTokens) · cache \(run.state.cacheReadTokens)/\(run.state.cacheCreationTokens)")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !run.agent.status.isTerminal {
                Button(role: .destructive) {
                    spawner.cancel(taskId: task.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text("Kill").font(.system(.callout))
                    }
                    .foregroundStyle(Palette.error)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Button {
                    spawner.dismiss(taskId: task.id)
                } label: {
                    Text("Done")
                        .font(.system(.callout).weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Dismiss this run — the inspector goes back to the task editor.")
            }
        }
    }

    // MARK: Helpers

    private func prettyModelName(_ raw: String) -> String {
        if let m = ModelRouter.Model(rawValue: raw) { return m.displayName }
        return raw
    }

    private func elapsed(since start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }
}

// MARK: - Event timeline

private struct EventTimeline: View {
    let state: AgentState
    let hint: String

    var body: some View {
        if state.events.isEmpty && hint.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the worker to come up…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !hint.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(hint).font(AtelierFont.caption)
                                    .foregroundStyle(Color.atelierInkSecondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                        }
                        ForEach(state.events) { event in
                            EventCardRow(event: event).id(event.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.events.count) { _, _ in
                    if let last = state.events.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

