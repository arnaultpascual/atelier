// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Review banner for tasks in the Review column. Adapts to whatever the worker
/// produced:
/// - If there's text (analysis / recap / summary) → show it scrollable up top.
/// - If there's a code diff → show shortstat + worktree / merge / discard actions.
/// - Always: Discard + Mark as Done at the bottom.
struct ReviewSection: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    let task: AtelierTask
    let project: Project
    var onIterate: (() -> Void)? = nil

    @State private var diffStat: GitService.DiffStat?
    @State private var changedFiles: [GitService.ChangedFile] = []
    @State private var loadingDiff: Bool = false
    @State private var diffError: String?
    @State private var presentingDiscard: Bool = false
    @State private var preview: PreviewItem?
    @State private var conversationExpanded: Bool = false
    @State private var diskEvents: [StreamEvent] = []
    @State private var diskEventsLoaded: Bool = false
    @State private var presentingReview: Bool = false
    @State private var merging: Bool = false
    @State private var mergeError: String?

    private struct PreviewItem: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let status: GitService.ChangeStatus
    }

    private var branch: String { "worktree-\(task.id)" }
    private var worktreePath: String {
        URL(fileURLWithPath: project.path)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(task.id)
            .path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            conversationPanel
            diffPanel
            if let mergeError {
                CalloutBanner(.danger, mergeError)
            }
            actionsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.atelierAccentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.card)
                .stroke(Color.atelierAccent.opacity(0.3), lineWidth: 1)
        )
        .task {
            await refreshDiff()
            await loadDiskTranscript()
        }
        .onChange(of: task.id) { _, _ in
            Task {
                await refreshDiff()
                await loadDiskTranscript()
            }
        }
        .sheet(item: $preview) { item in
            FilePreviewSheet(
                projectPath: project.path,
                taskId: task.id,
                relativePath: item.path,
                changeStatus: item.status,
                onClose: { preview = nil }
            )
        }
        .sheet(isPresented: $presentingReview) {
            WorktreeReviewSheet(task: task, project: project,
                                onClose: { presentingReview = false })
                .frame(minWidth: 820, idealWidth: 1000, maxWidth: 1400,
                       minHeight: 620, idealHeight: 820, maxHeight: 1200)
        }
        .confirmationDialog("Discard the worktree for this task?", isPresented: $presentingDiscard, titleVisibility: .visible) {
            Button("Discard & move to To Do", role: .destructive) { Task { await discardWorktree(then: .toDo) } }
            Button("Discard & delete task", role: .destructive) { Task { await discardWorktree(then: .delete) } }
            Button("Discard only (stay in Review)") { Task { await discardWorktree(then: .stay) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes the \(branch) worktree and branch. Choose what happens to the task itself.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(Color.atelierAccent)
            Text("In review")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierAccent)
            Text(branch)
                .font(AtelierFont.captionMono.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button(action: { Task { await refreshDiff() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Re-run `git diff --shortstat`.")
        }
    }

    // MARK: Worker conversation (full transcript of the run)

    @ViewBuilder
    private var conversationPanel: some View {
        let (events, source) = conversationSource
        if events.isEmpty {
            if !diskEventsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading claude session log…")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .padding(10)
                .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text("No worker conversation found for this task.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.atelierAccent)
                        .fixedSize()
                    Text("Conversation")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                        .fixedSize()
                    Text("\(events.count)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .fixedSize()
                    Text("· \(source)")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    iconButton(system: conversationExpanded ? "chevron.up" : "chevron.down",
                               help: conversationExpanded ? "Collapse conversation" : "Expand conversation") {
                        conversationExpanded.toggle()
                    }
                }
                if conversationExpanded {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(events) { event in
                                EventCardRow(event: event)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
                    .clipped()
                } else if let last = lastAssistantText(from: events) {
                    Text("…\(last.suffix(160))")
                        .font(AtelierFont.caption.italic())
                        .foregroundStyle(Color.atelierInkSecondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Returns the best available transcript + a label describing its source. Live
    /// in-memory wins; otherwise we fall back to the persisted JSONL claude wrote.
    private var conversationSource: (events: [StreamEvent], label: String) {
        if let run = spawner.activeRun(for: task.id), !run.state.events.isEmpty {
            return (run.state.events, "live")
        }
        if !diskEvents.isEmpty {
            return (diskEvents, "from session log")
        }
        return ([], "")
    }

    private func lastAssistantText(from events: [StreamEvent]) -> String? {
        for event in events.reversed() {
            if case .assistant(let text, _, _) = event.kind, let t = text, !t.isEmpty {
                return t
            }
        }
        return nil
    }

    // MARK: Diff panel

    @ViewBuilder
    private var diffPanel: some View {
        if loadingDiff {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading git diff…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        } else if let stat = diffStat, !stat.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text("Changes")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                    if stat.insertions > 0 {
                        Text("+\(stat.insertions)")
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Palette.success)
                    }
                    if stat.deletions > 0 {
                        Text("−\(stat.deletions)")
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Palette.error)
                    }
                }
                if !changedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changedFiles) { file in
                            ChangedFileRow(file: file) {
                                preview = PreviewItem(path: file.path, status: file.status)
                            }
                        }
                    }
                    .padding(6)
                    .background(Color.atelierBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
                }
                if task.status != .done {
                    mergeCommandBlock
                    HStack(spacing: 6) {
                        pillButton(label: "Reveal worktree", icon: "folder", action: revealWorktree)
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        } else if let stat = diffStat, stat.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "minus.circle").font(.system(size: 10))
                Text("No code changes vs. HEAD — pure analysis run.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        } else if let err = diffError {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                Text(err).font(AtelierFont.caption).lineLimit(2)
            }
            .foregroundStyle(Palette.warning)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionsRow: some View {
        if task.status == .done {
            doneActionsRow
        } else {
            reviewActionsRow
        }
    }

    /// Full action set while the task is still being reviewed.
    private var reviewActionsRow: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                presentingDiscard = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 10))
                    Text("Discard").font(.system(.callout))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(Palette.error)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Removes the worktree and the worktree-\(task.id) branch.")

            Spacer()

            Button(action: { presentingReview = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Review with Opus")
                        .font(.system(.callout).weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(Color.atelierInk)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Spawn Opus 4.7 to read the diff and produce a structured MR-style review.")

            if let onIterate {
                Button(action: onIterate) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Iterate")
                            .font(.system(.callout).weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.atelierAccent)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierAccent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Resume this session and keep talking with claude.")
            }

            Button(action: mergeInApp) {
                HStack(spacing: 4) {
                    if merging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.merge").font(.system(size: 10, weight: .semibold))
                    }
                    Text(merging ? "Merging…" : "Merge").font(.system(.callout).weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(merging)
            .help("Merge worktree-\(task.id) into your current branch (--no-ff), mark the task Done, and remove the worktree. Conflicts abort cleanly so you can resolve by hand.")

            Button(action: markDone) {
                Text("Mark as Done")
                    .font(.system(.callout).weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(merging)
            .help("Move to Done without an in-app merge — e.g. if you merged manually or won't merge.")
        }
    }

    /// Once the task is Done the section becomes a read-only recap. Only
    /// Iterate stays (so the user can still revisit / discuss with claude).
    private var doneActionsRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Palette.success)
                Text("Done")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Palette.success)
            }
            Text("recap is read-only — move the task back to Review to act on it.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
            if let onIterate {
                Button(action: onIterate) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Iterate")
                            .font(.system(.callout).weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.atelierAccent)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierAccent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Resume the session to ask follow-up questions about the completed work.")
            }
        }
    }

    private var mergeCommandBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To merge into your project, paste this in your terminal:")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            HStack(alignment: .top, spacing: 8) {
                Text(mergeCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copyMergeCommand) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the command to the clipboard")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.atelierBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.7), lineWidth: 1))
        }
    }

    private var mergeCommand: String {
        "git -C \"\(project.path)\" merge --no-ff \(branch)"
    }

    private func pillButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(AtelierFont.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.atelierInkSecondary)
            .background(Color.atelierSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func iconButton(system: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.atelierInkSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(Color.atelierSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    // MARK: - Derived

    // MARK: - Side effects

    /// Tries to read claude's persisted JSONL for this task's worktree. If a session
    /// id is known from the in-memory run, use it directly; otherwise take the latest
    /// jsonl in the encoded-cwd directory.
    private func loadDiskTranscript() async {
        let sessionId = spawner.activeRun(for: task.id)?.agent.sessionId
        let events: [StreamEvent]?
        if let sessionId, !sessionId.isEmpty {
            events = SessionReader.loadEvents(cwd: worktreePath, sessionId: sessionId)
        } else {
            events = SessionReader.loadLatestSession(cwd: worktreePath)
        }
        await MainActor.run {
            self.diskEvents = events ?? []
            self.diskEventsLoaded = true
        }
    }

    private func refreshDiff() async {
        loadingDiff = true
        diffError = nil
        do {
            let stat = try await GitService.diffStat(projectPath: project.path, branch: branch)
            let files = (try? await GitService.changedFiles(projectPath: project.path,
                                                            branch: branch,
                                                            taskId: task.id)) ?? []
            await MainActor.run {
                self.diffStat = stat
                self.changedFiles = files
                self.loadingDiff = false
            }
        } catch {
            await MainActor.run {
                self.diffStat = nil
                self.changedFiles = []
                self.diffError = error.localizedDescription
                self.loadingDiff = false
            }
        }
    }

    private func revealWorktree() {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktreePath)])
    }

    private func copyMergeCommand() {
        copyToPasteboard(mergeCommand)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func markDone() {
        Task { try? await store.updateTaskStatus(task, to: .done) }
    }

    /// Merge the task's worktree branch into the project's current branch with `--no-ff` (the same
    /// plumbing autopilot uses), then mark the task Done and remove the worktree. A conflict aborts
    /// cleanly and points the user at the copyable command to resolve by hand.
    private func mergeInApp() {
        merging = true
        mergeError = nil
        Task {
            defer { merging = false }
            do {
                let base = try await GitService.currentBranch(projectPath: project.path)
                let result = try await GitService.merge(into: base, branch: branch, projectPath: project.path)
                switch result {
                case .clean, .upToDate:
                    try? await GitService.removeWorktree(projectPath: project.path, taskId: task.id, force: false)
                    try? await store.updateTaskStatus(task, to: .done)
                case .conflict(let files):
                    try? await GitService.abortMerge(projectPath: project.path)
                    let names = files.prefix(3).joined(separator: ", ")
                    mergeError = "Merge has conflicts in \(files.count) file\(files.count == 1 ? "" : "s") (\(names)\(files.count > 3 ? "…" : "")). Aborted to keep your tree clean — use the command above to merge and resolve them by hand."
                }
            } catch {
                mergeError = error.localizedDescription
            }
        }
    }

    private enum DiscardOutcome { case stay, toDo, delete }

    private func discardWorktree(then outcome: DiscardOutcome) async {
        do {
            try await GitService.removeWorktree(projectPath: project.path, taskId: task.id, force: true)
            switch outcome {
            case .stay: break
            case .toDo: try? await store.updateTaskStatus(task, to: .toDo)
            case .delete: try? await store.deleteTask(task)
            }
        } catch {
            await MainActor.run {
                diffError = error.localizedDescription
            }
        }
    }
}

// MARK: - Changed-file row

private struct ChangedFileRow: View {
    let file: GitService.ChangedFile
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(file.status.symbol)
                    .font(AtelierFont.captionMono.weight(.bold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 14)
                Text(file.path)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(file.status.label)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary.opacity(hover ? 1.0 : 0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hover ? Color.atelierAccentSoft.opacity(0.5) : Color.clear)
        )
        .onHover { hover = $0 }
        .help("Preview \(file.path) in-app")
    }

    private var symbolColor: Color {
        switch file.status {
        case .added, .untracked: return Palette.success
        case .modified: return Color.atelierAccent
        case .deleted: return Palette.error
        case .renamed: return Palette.warning
        case .other: return Color.atelierInkSecondary
        }
    }
}
