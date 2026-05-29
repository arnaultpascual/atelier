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
    @State private var diskEvents: [StreamEvent] = []
    @State private var diskMessages: [ChatMessage] = []
    @State private var diskEventsLoaded: Bool = false
    @State private var inspectorTab: InspectorTab = .changes
    @State private var conversationMode: ConversationMode = .readable
    @State private var review = ReviewSession()
    @State private var persistedReview: String?
    @State private var runDuration: TimeInterval?
    @State private var merging: Bool = false
    @State private var mergeError: String?
    @State private var presentingProtectedMerge = false
    @State private var pendingBase: String = ""
    @State private var newBranchName: String = ""

    private struct PreviewItem: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let status: GitService.ChangeStatus
    }

    /// The three things you can look at for a finished worktree. One inspector,
    /// one selection — instead of three stacked panels fighting for the eye.
    private enum InspectorTab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case conversation = "Conversation"
        case review = "Opus review"
        var id: String { rawValue }
    }

    /// How the conversation renders — clean chat bubbles or the raw event stream.
    private enum ConversationMode { case readable, raw }

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
            inspector
            if let mergeError {
                CalloutBanner(.danger, mergeError)
            }
            actionsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.card)
                .stroke(Color.atelierDivider, lineWidth: 1)
        )
        .task {
            loadPersistedReview()
            await refreshDiff()
            await loadDiskTranscript()
            await loadRunDuration()
        }
        .onChange(of: task.id) { _, _ in
            persistedReview = nil
            runDuration = nil
            loadPersistedReview()
            Task {
                await refreshDiff()
                await loadDiskTranscript()
                await loadRunDuration()
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
        .confirmationDialog("Discard the worktree for this task?", isPresented: $presentingDiscard, titleVisibility: .visible) {
            Button("Discard & move to To Do", role: .destructive) { Task { await discardWorktree(then: .toDo) } }
            Button("Discard & delete task", role: .destructive) { Task { await discardWorktree(then: .delete) } }
            Button("Discard only (stay in Review)") { Task { await discardWorktree(then: .stay) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes the \(branch) worktree and branch. Choose what happens to the task itself.")
        }
        .alert("Merge onto \(pendingBase)?", isPresented: $presentingProtectedMerge) {
            TextField("new branch name", text: $newBranchName)
            Button("Create branch & merge") { createBranchAndMerge() }
            Button("Merge onto \(pendingBase) anyway", role: .destructive) { mergeOntoBaseAnyway() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You're on “\(pendingBase)”, a protected branch. Recommended: create a new branch off it and merge the task there, keeping \(pendingBase) clean.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.status == .done ? "checkmark.seal.fill" : "magnifyingglass.circle.fill")
                .foregroundStyle(task.status == .done ? Palette.success : Color.atelierAccent)
            Text(task.status == .done ? "Done" : "In review")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(task.status == .done ? Palette.success : Color.atelierAccent)
            Text(branch)
                .font(AtelierFont.captionMono.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let stat = diffStat, !stat.isEmpty {
                Text("+\(stat.insertions) −\(stat.deletions) · \(changedFiles.count) file\(changedFiles.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            } else if !worktreeExists {
                Text(task.status == .done ? "· merged & removed" : "· worktree removed")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(task.status == .done ? Palette.success.opacity(0.9) : Color.atelierInkSecondary)
            }
            if let runDuration {
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text(formatDuration(runDuration)).font(AtelierFont.captionMono)
                }
                .foregroundStyle(Color.atelierInkSecondary)
                .help("Total worker execution time for this task.")
            }
            Spacer()
            if let verdict = parsedVerdict {
                verdictChip(verdict)
            }
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

    // MARK: Inspector (one panel, focused views)

    private var worktreeExists: Bool {
        FileManager.default.fileExists(atPath: worktreePath)
    }

    /// Tabs worth showing for the current state. Changes needs a live worktree
    /// (nothing to diff once it's merged & removed — that fact is stated once in
    /// the header). Conversation and Opus review always show: the review tab is
    /// where any saved review lives, a CTA to run one, or an honest "none saved".
    private var availableTabs: [InspectorTab] {
        var tabs: [InspectorTab] = []
        if worktreeExists { tabs.append(.changes) }
        tabs.append(.conversation)
        tabs.append(.review)
        return tabs
    }

    /// Everything you can look at for a finished worktree, behind a single
    /// segmented control. Replaces three stacked collapsibles with one focus.
    private var inspector: some View {
        let tabs = availableTabs
        // On a finished task with a saved review, lead with it (the verdict is the
        // point); otherwise fall back to the first available tab.
        let preferred: InspectorTab = (task.status == .done && persistedReview != nil) ? .review : (tabs.first ?? .conversation)
        let selection = tabs.contains(inspectorTab) ? inspectorTab : preferred
        return VStack(alignment: .leading, spacing: 8) {
            if tabs.count > 1 {
                Picker("", selection: Binding(get: { selection }, set: { inspectorTab = $0 })) {
                    ForEach(tabs) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Group {
                switch selection {
                case .changes:      changesTab
                case .conversation: conversationTab
                case .review:       reviewTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Changes tab

    @ViewBuilder
    private var changesTab: some View {
        if loadingDiff {
            loadingRow("Reading git diff…")
        } else if let stat = diffStat, !stat.isEmpty {
            if changedFiles.isEmpty {
                noteRow("doc.text.magnifyingglass",
                        "+\(stat.insertions) −\(stat.deletions) — open the worktree to inspect the change.")
            } else {
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
        } else if let stat = diffStat, stat.isEmpty {
            // The Changes tab only shows when the worktree exists, so an empty
            // stat here means a pure-analysis run (the merged & removed case is
            // stated once in the header instead).
            noteRow("minus.circle", "No code changes vs. HEAD — pure analysis run.")
        } else if let err = diffError {
            noteRow("exclamationmark.triangle", err, color: Palette.warning)
        } else {
            loadingRow("Reading git diff…")
        }
    }

    // MARK: Conversation tab (clean bubbles or the raw event stream)

    @ViewBuilder
    private var conversationTab: some View {
        let (events, source) = conversationSource
        let messages = conversationMessages
        if events.isEmpty && messages.isEmpty {
            if !diskEventsLoaded {
                loadingRow("Reading claude session log…")
            } else {
                noteRow("bubble.left.and.bubble.right", "No worker conversation found for this task.")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(conversationMode == .readable
                         ? "\(messages.count) message\(messages.count == 1 ? "" : "s")"
                         : "\(events.count) event\(events.count == 1 ? "" : "s")")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text("· \(source)")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    conversationModeToggle
                }
                if conversationMode == .readable {
                    readableConversation(messages)
                } else {
                    rawConversation(events)
                }
            }
        }
    }

    private var conversationModeToggle: some View {
        HStack(spacing: 0) {
            convModePill(label: "Chat", selected: conversationMode == .readable) { conversationMode = .readable }
            convModePill(label: "Detail", selected: conversationMode == .raw) { conversationMode = .raw }
        }
        .padding(2)
        .background(Color.atelierSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func convModePill(label: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(AtelierFont.captionMono.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.atelierAccent : Color.atelierInkSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(selected ? Color.atelierAccentSoft.opacity(0.7) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func readableConversation(_ messages: [ChatMessage]) -> some View {
        if messages.isEmpty {
            noteRow("text.bubble", "This worker mostly ran tools — switch to Detail to see its activity.")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { msg in
                        ChatBubble(message: msg)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: 460)
            .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            .clipped()
        }
    }

    private func rawConversation(_ events: [StreamEvent]) -> some View {
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
        .frame(maxWidth: .infinity, maxHeight: 460)
        .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
        .clipped()
    }

    /// Clean chat-style turns for the "Chat" conversation mode. Prefers the real
    /// user+assistant messages parsed from claude's JSONL; falls back to assistant
    /// prose pulled from whatever events we have, opened with the task brief.
    private var conversationMessages: [ChatMessage] {
        if !diskMessages.isEmpty { return diskMessages }
        let (events, _) = conversationSource
        guard !events.isEmpty else { return [] }
        var msgs: [ChatMessage] = []
        let brief = briefText
        if !brief.isEmpty {
            msgs.append(ChatMessage(role: .user, text: brief, at: events.first?.timestamp ?? Date()))
        }
        for event in events {
            if case .assistant(let text, _, _) = event.kind,
               let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                msgs.append(ChatMessage(role: .assistant, text: t, at: event.timestamp))
            }
        }
        // A lone brief bubble (no assistant prose) isn't worth showing on its own.
        return msgs.contains(where: { $0.role == .assistant }) ? msgs : []
    }

    private var briefText: String {
        let d = (task.descriptionMd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? task.title : d
    }

    // MARK: Opus review tab (inline — no modal)

    @ViewBuilder
    private var reviewTab: some View {
        switch review.status {
        case .idle:      reviewIdleState
        case .running:   reviewRunningState
        case .completed: reviewResultState
        case .failed:    reviewFailedState
        }
    }

    /// No live review in memory → show a saved one if we have it (autopilot's or
    /// a previous on-demand run), otherwise offer to run one, or note there's none.
    @ViewBuilder
    private var reviewIdleState: some View {
        if let md = persistedReview {
            savedReviewState(md)
        } else if worktreeExists {
            reviewCTA
        } else {
            noteRow("doc.text.magnifyingglass", "No saved Opus review for this task.")
        }
    }

    private var reviewCTA: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.atelierAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Opus 4.8 code review")
                        .font(AtelierFont.callout.weight(.semibold))
                        .foregroundStyle(Color.atelierInk)
                    Text("Reads the diff and changed files, then writes a PR-style review — summary, risks, tests, and a merge verdict.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: startReview) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal").font(.system(size: 10, weight: .semibold))
                        Text("Review with Opus").font(.system(.callout).weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                }
                .buttonStyle(.plain)
                .fixedSize()
                Text("Read-only · costs a few cents in tokens")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.atelierBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    /// A review that was persisted to `.atelier/` — autopilot's at merge time, or
    /// a previous on-demand run — rendered read-only with the parsed verdict.
    private func savedReviewState(_ md: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let v = parsedVerdict { verdictChip(v) }
                Text("Saved review")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer(minLength: 0)
                Button(action: { copyToPasteboard(md) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy review as markdown")
                if worktreeExists {
                    Button(action: startReview) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.atelierInkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Run a fresh Opus review")
                }
            }
            reviewMarkdownScroll(md)
        }
    }

    private var reviewRunningState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Opus 4.8 reviewing…")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer(minLength: 0)
                if review.totalCostUsd > 0 { costText }
            }
            if review.outputText.isEmpty {
                noteRow("text.viewfinder", "Reading the diff, walking changed files, drafting the review…")
            } else {
                reviewMarkdownScroll(review.outputText)
            }
        }
    }

    private var reviewResultState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let v = parsedVerdict { verdictChip(v) }
                Spacer(minLength: 0)
                if review.totalCostUsd > 0 { costText }
                Button(action: copyReview) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy review as markdown")
                Button(action: startReview) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .buttonStyle(.plain)
                .help("Re-run the Opus review")
            }
            reviewMarkdownScroll(review.outputText)
            if let err = review.errorMessage {
                Text(err).font(AtelierFont.caption).foregroundStyle(Palette.error)
            }
        }
    }

    private var reviewFailedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            noteRow("exclamationmark.triangle", review.errorMessage ?? "Review failed.", color: Palette.error)
            Button(action: startReview) {
                Text("Try again").font(.system(.callout).weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .foregroundStyle(Color.atelierInk)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func reviewMarkdownScroll(_ markdown: String) -> some View {
        ScrollView(.vertical) {
            MarkdownView(source: markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: 460)
        .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
        .clipped()
    }

    private var costText: some View {
        Text(String(format: "$%.4f", review.totalCostUsd))
            .font(AtelierFont.captionMono.weight(.semibold))
            .foregroundStyle(Color.atelierAccent)
    }

    private func startReview() {
        Task {
            await review.start(task: task, project: project)
            // Persist a successful on-demand review so it survives the merge into
            // the Done recap — same idea as autopilot's saved report.
            if review.status == .completed, !review.outputText.isEmpty {
                persistReview(review.outputText)
            }
        }
    }

    private func copyReview() {
        copyToPasteboard(review.outputText)
    }

    /// Loads the most relevant saved review for this task: a previous on-demand
    /// run (`.atelier/reviews/<id>.md`) wins over autopilot's merge-time report
    /// (`.atelier/autopilot/<id>.md`). Both survive worktree removal.
    private func loadPersistedReview() {
        let base = URL(fileURLWithPath: project.path)
        for sub in [".atelier/reviews", ".atelier/autopilot"] {
            let url = base.appendingPathComponent(sub).appendingPathComponent("\(task.id).md")
            if let md = try? String(contentsOf: url, encoding: .utf8),
               !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                persistedReview = md
                return
            }
        }
    }

    private func persistReview(_ markdown: String) {
        let dir = URL(fileURLWithPath: project.path).appendingPathComponent(".atelier/reviews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? markdown.write(to: dir.appendingPathComponent("\(task.id).md"), atomically: true, encoding: .utf8)
        persistedReview = markdown
    }

    // MARK: Verdict (parsed from the review's "Verdict" line)

    /// The verdict to badge in the header: from the live review if one just ran,
    /// otherwise from whatever review is saved on disk.
    private var parsedVerdict: ReviewVerdict? {
        if review.status == .completed, !review.outputText.isEmpty {
            return verdictFromText(review.outputText)
        }
        if let md = persistedReview {
            return verdictFromText(md)
        }
        return nil
    }

    /// Reads the verdict out of either review format: the on-demand markdown
    /// ("## Verdict\nAPPROVE…") or autopilot's persisted file
    /// ("**Verdict:** changesRequested"). Scans a short window after the last
    /// "Verdict" so a stray word elsewhere can't flip it.
    private func verdictFromText(_ text: String) -> ReviewVerdict? {
        let scope: String
        if let r = text.range(of: "Verdict", options: [.caseInsensitive, .backwards]) {
            scope = String(text[r.upperBound...].prefix(80))
        } else {
            scope = text
        }
        let up = scope.uppercased()
        if up.contains("APPROVE") { return .approve }
        if up.contains("CHANGES") { return .changesRequested }
        if up.contains("NEEDS") || up.contains("DISCUSS") { return .needsDiscussion }
        return nil
    }

    @ViewBuilder
    private func verdictChip(_ v: ReviewVerdict) -> some View {
        let m = verdictMeta(v)
        HStack(spacing: 4) {
            Image(systemName: m.icon).font(.system(size: 9, weight: .semibold))
            Text(m.label).font(AtelierFont.eyebrow)
        }
        .foregroundStyle(m.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(m.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(m.color.opacity(0.3), lineWidth: 1))
    }

    private func verdictMeta(_ v: ReviewVerdict) -> (label: String, icon: String, color: Color) {
        switch v {
        case .approve:          return ("Opus · Approve", "checkmark.seal.fill", Palette.success)
        case .changesRequested: return ("Opus · Changes", "exclamationmark.triangle.fill", Palette.warning)
        case .needsDiscussion:  return ("Opus · Discuss", "questionmark.circle.fill", Color.atelierInkSecondary)
        }
    }

    // MARK: Small shared rows

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private func noteRow(_ icon: String, _ text: String, color: Color = Color.atelierInkSecondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(AtelierFont.caption).foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
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

            Menu {
                Button("Copy merge command") { copyMergeCommand() }
                Button("Reveal worktree", action: revealWorktree)
                Divider()
                Button("Mark as Done without merging") { markDone() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Merge manually (copy the command), reveal the worktree, or mark Done without merging.")

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
                    .foregroundStyle(Color.atelierInkSecondary)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
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

        }
    }

    /// Once the task is Done the section becomes a read-only recap. The status
    /// lives in the header; here we just label the recap and keep Iterate (so the
    /// user can still resume / discuss with claude).
    private var doneActionsRow: some View {
        HStack(spacing: 8) {
            Text("Read-only recap")
                .font(AtelierFont.eyebrow)
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
                    .foregroundStyle(Color.atelierInkSecondary)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Resume the session to ask follow-up questions about the completed work.")
            }
        }
    }

    private var mergeCommand: String {
        "git -C \"\(project.path)\" merge --no-ff \(branch)"
    }

    // MARK: - Derived

    // MARK: - Side effects

    /// Reads claude's persisted JSONL for this task's worktree, as both the raw
    /// event stream (Detail mode) and clean user+assistant messages (Chat mode).
    /// If a session id is known from the in-memory run we use it directly;
    /// otherwise we resolve the latest jsonl in the encoded-cwd directory. The
    /// JSONL survives worktree removal, so this still works for merged Done tasks.
    private func loadDiskTranscript() async {
        let liveId = spawner.activeRun(for: task.id)?.agent.sessionId
        let sessionId = (liveId?.isEmpty == false ? liveId : nil)
            ?? SessionReader.latestSessionId(cwd: worktreePath)
        let events: [StreamEvent]
        let messages: [ChatMessage]
        if let sessionId {
            events = SessionReader.loadEvents(cwd: worktreePath, sessionId: sessionId) ?? []
            messages = ChatJSONLReader.messages(cwd: worktreePath, sessionId: sessionId)
        } else {
            events = SessionReader.loadLatestSession(cwd: worktreePath) ?? []
            messages = []
        }
        await MainActor.run {
            self.diskEvents = events
            self.diskMessages = messages
            self.diskEventsLoaded = true
        }
    }

    /// Total worker execution time for this task — sums each agent run's
    /// startedAt→endedAt (covers re-runs / autopilot fix passes), so it reflects
    /// real work, not idle time between sessions.
    private func loadRunDuration() async {
        let agents = (try? await store.agentsForTask(task.id)) ?? []
        let total = agents.reduce(0.0) { acc, a in
            guard let s = a.startedAt, let e = a.endedAt, e > s else { return acc }
            return acc + e.timeIntervalSince(s)
        }
        await MainActor.run { runDuration = total > 0 ? total : nil }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m == 0 ? "\(h)h" : "\(h)h\(m)m" }
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
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

    private static let protectedBranches: Set<String> = ["main", "master", "develop", "development", "trunk", "release"]

    /// Merge the task's worktree branch into the project's current branch with `--no-ff` (the same
    /// plumbing autopilot uses), then mark the task Done and remove the worktree. If the current
    /// branch is protected (main / develop / …), it does NOT merge — it offers to create a feature
    /// branch first. A conflict aborts cleanly and points the user at the copyable command.
    private func mergeInApp() {
        merging = true
        mergeError = nil
        Task {
            do {
                let base = try await GitService.currentBranch(projectPath: project.path)
                if Self.protectedBranches.contains(base.lowercased()) {
                    pendingBase = base
                    if newBranchName.isEmpty { newBranchName = "feature/\(BacklogMD.slugify(task.title))" }
                    merging = false
                    presentingProtectedMerge = true
                    return
                }
                await performMerge(into: base)
            } catch {
                mergeError = error.localizedDescription
                merging = false
            }
        }
    }

    /// Create `newBranchName` off the current (protected) branch, then merge the task onto it.
    private func createBranchAndMerge() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        merging = true
        mergeError = nil
        Task {
            do {
                try await GitService.createIntegrationBranch(projectPath: project.path, branch: name)
                await performMerge(into: name)
            } catch {
                mergeError = error.localizedDescription
                merging = false
            }
        }
    }

    private func mergeOntoBaseAnyway() {
        merging = true
        mergeError = nil
        Task { await performMerge(into: pendingBase) }
    }

    private func performMerge(into base: String) async {
        do {
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
        merging = false
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
