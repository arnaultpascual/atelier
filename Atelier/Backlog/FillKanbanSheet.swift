// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Live progress lines for the "inspect repo" decompose, fed from claude's
/// stream-json tool-use events. MainActor + Observable so the running view
/// can update as the model reads files.
@MainActor @Observable final class DecomposeActivity {
    private(set) var lines: [String] = []
    func push(_ line: String) {
        guard lines.last != line else { return }   // collapse repeats
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }
    func reset() { lines = [] }
}

/// "Fill kanban" flow. User pastes a brief or spec, Opus 4.7 decomposes it
/// into task drafts, user reviews / tweaks / deletes individual ones, then
/// hits "Create all" to persist.
///
/// Drafts are kept in local @State until persisted — nothing touches the
/// kanban until the user confirms.
struct FillKanbanSheet: View {
    @Bindable var store: AppStore
    let project: Project
    let onClose: () -> Void

    @State private var brief: String = ""
    @State private var phase: Phase = .compose
    @State private var drafts: [AIAssistant.TaskDraft] = []
    @State private var attachments: [URL] = []
    @State private var inspectRepo: Bool = false
    @State private var isDropTargeted = false
    @State private var error: String?
    @State private var saveError: String?
    @State private var activity = DecomposeActivity()
    @State private var runningSince: Date?
    @State private var decomposeTask: Task<Void, Never>?
    @FocusState private var briefFocused: Bool

    private enum Phase: Equatable {
        case compose
        case running
        case review
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            content
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .frame(minWidth: 700, idealWidth: 820, maxWidth: 1100,
               minHeight: 540, idealHeight: 640, maxHeight: 900)
        .background(Color.atelierBackground)
        .onDisappear { decomposeTask?.cancel() }   // never orphan the claude subprocess
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.atelierAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fill kanban")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("\(project.name) · Opus 4.7 decomposes a brief into kanban-ready tasks.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .compose: composeView
        case .running: runningView
        case .review:  reviewView
        }
    }

    // MARK: Compose

    private var composeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BRIEF / SPEC")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $brief)
                    .font(.system(.body, design: .default))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                    .focused($briefFocused)
                if brief.isEmpty {
                    Text("Paste a brief, RFC, ticket dump, sprint goals, anything. Opus will chunk it into runnable tasks with title, description, priority, labels and suggested model.")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 280)

            attachmentsStrip

            inspectRepoToggle

            if let err = error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var inspectRepoToggle: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $inspectRepo) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inspect the repo before decomposing")
                    .font(AtelierFont.caption.weight(.medium))
                    .foregroundStyle(Color.atelierInk)
                Text("Opus reads your actual code (Glob/Grep/Read) so tasks reference real files. Slower (~30–90s) and a bit pricier per run.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: Attachments

    private var attachmentsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("ATTACHMENTS")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer()
                Button(action: pickAttachments) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                        Text("Add").font(AtelierFont.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Images, PDFs and text files are sent to Opus as extra context — it pulls the details into each task.")
            }
            if attachments.isEmpty {
                attachmentsEmptyState
            } else {
                attachmentsList
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var attachmentsEmptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 11))
                .foregroundStyle(Color.atelierInkSecondary)
            Text(isDropTargeted
                 ? "Drop to attach"
                 : "Drag images, PDFs or text here — Opus reads them as context.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .fill(isDropTargeted ? Color.atelierAccentSoft.opacity(0.5) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .strokeBorder(
                    isDropTargeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
    }

    private var attachmentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(attachments, id: \.self) { url in
                    attachmentRow(url)
                }
            }
        }
        .frame(maxHeight: 132)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .fill(isDropTargeted ? Color.atelierAccentSoft.opacity(0.5) : Color.atelierSurface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.control)
                .stroke(isDropTargeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.6),
                        lineWidth: isDropTargeted ? 1.5 : 1)
        )
    }

    private func attachmentRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachmentIcon(for: url))
                .font(.system(size: 12))
                .foregroundStyle(Color.atelierAccent)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(AtelierFont.callout)
                .foregroundStyle(Color.atelierInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                attachments.removeAll { $0 == url }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func attachmentIcon(for url: URL) -> String {
        guard let ct = UTType(filenameExtension: url.pathExtension.lowercased()) else { return "doc" }
        if ct.conforms(to: .image) { return "photo" }
        if ct.conforms(to: .pdf) { return "doc.richtext" }
        if ct.conforms(to: .sourceCode) || ct.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach context for the decomposition"
        panel.message = "Images, PDFs and text files are sent to Opus as extra context."
        if panel.runModal() == .OK {
            addAttachments(panel.urls)
        }
    }

    private func addAttachments(_ urls: [URL]) {
        for url in urls where !attachments.contains(where: { $0.path == url.path }) {
            attachments.append(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            anyHandled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in addAttachments([url]) }
            }
        }
        return anyHandled
    }

    // MARK: Running

    private var runningView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(inspectRepo ? "Opus 4.7 is reading your repo, then decomposing…" : "Opus 4.7 is decomposing your brief…")
                .font(AtelierFont.callout)
                .foregroundStyle(Color.atelierInk)
            Text(inspectRepo
                 ? "Inspecting a repo can take 1–3 minutes (it stops automatically if it runs long). The model is reading your code (Glob/Grep/Read), then chunking into self-contained, dependency-aware tasks."
                 : "Usually 10–30 seconds. The model is chunking into self-contained, dependency-aware tasks and choosing a model per task.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .multilineTextAlignment(.center)
            elapsedCounter
            if !activity.lines.isEmpty {
                activityTicker
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(22)
    }

    /// Always-moving heartbeat so a quiet stretch never looks frozen.
    private var elapsedCounter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let secs = max(0, Int(Date().timeIntervalSince(runningSince ?? Date())))
            Text(String(format: "working · %d:%02d", secs / 60, secs % 60))
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                .contentTransition(.numericText())
        }
    }

    /// Live feed of what Opus is doing while it inspects the repo — last few
    /// actions, newest highlighted, so a 2–3 min wait is transparent.
    private var activityTicker: some View {
        let recent = Array(activity.lines.suffix(6).enumerated())
        let lastIdx = recent.count - 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(recent, id: \.offset) { idx, line in
                let isLast = idx == lastIdx
                HStack(spacing: 6) {
                    Image(systemName: isLast ? "arrow.right" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isLast ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.5))
                        .frame(width: 12)
                    Text(line)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(isLast ? Color.atelierInk : Color.atelierInkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .opacity(isLast ? 1 : 0.7)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(12)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: activity.lines.count)
    }

    // MARK: Review

    private var reviewView: some View {
        let waves = executionWaves()
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(reviewSummary(waveCount: waves.count))
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                if waves.count > 1 {
                    ForEach(Array(waves.enumerated()), id: \.offset) { idx, wave in
                        roundHeader(round: idx + 1, count: wave.count)
                        ForEach(wave) { draft in
                            draftRow(draft)
                        }
                    }
                } else {
                    ForEach(drafts) { draft in
                        draftRow(draft)
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.error)
                        .padding(.top, 8)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reviewSummary(waveCount: Int) -> String {
        let n = drafts.count
        let base = "\(n) draft\(n == 1 ? "" : "s") — review and remove any you don't want."
        return waveCount > 1 ? "\(base) Grouped into \(waveCount) execution rounds." : base
    }

    private func roundHeader(round: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Text("ROUND \(round)")
                .font(AtelierFont.eyebrow.weight(.semibold))
                .foregroundStyle(Color.atelierAccent)
            Text(count > 1 ? "\(count) in parallel" : "1 task")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            Rectangle().fill(Color.atelierDivider.opacity(0.5)).frame(height: 1)
        }
        .padding(.top, 6)
    }

    /// Groups the current drafts into execution waves derived from the dependency
    /// graph: round 1 = drafts with no (in-set) dependency, round N = drafts whose
    /// deepest dependency is in round N-1. Recomputed live as drafts are removed.
    private func executionWaves() -> [[AIAssistant.TaskDraft]] {
        let byRef = Dictionary(drafts.compactMap { d in d.ref.map { ($0, d) } },
                               uniquingKeysWith: { first, _ in first })
        var depthCache: [UUID: Int] = [:]
        var inProgress: Set<UUID> = []
        func depth(_ d: AIAssistant.TaskDraft) -> Int {
            if let cached = depthCache[d.id] { return cached }
            if inProgress.contains(d.id) { return 0 }   // cycle guard
            inProgress.insert(d.id)
            let deps = d.dependsOnRefs.compactMap { byRef[$0] }.filter { $0.id != d.id }
            let result = deps.isEmpty ? 0 : 1 + (deps.map { depth($0) }.max() ?? 0)
            inProgress.remove(d.id)
            depthCache[d.id] = result
            return result
        }
        let grouped = Dictionary(grouping: drafts) { depth($0) }
        return grouped.keys.sorted().map { grouped[$0]! }
    }

    private func draftRow(_ draft: AIAssistant.TaskDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.title)
                    .font(AtelierFont.callout.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(2)
                Spacer()
                if let p = draft.priority {
                    PriorityPill(priority: p)
                }
                if let model = draft.workerModel {
                    Text(modelShortName(model))
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Button(role: .destructive) {
                    drafts.removeAll { $0.id == draft.id }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.error)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Drop this draft")
            }
            if !draft.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(draft.labels, id: \.self) { label in
                        Text(label)
                            .font(AtelierFont.eyebrow)
                            .foregroundStyle(Color.atelierInkSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.atelierSurface, in: Capsule())
                            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                    }
                }
            }
            if !draft.dependsOnRefs.isEmpty {
                let names = dependencyTitles(for: draft)
                if !names.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.atelierInkSecondary)
                        Text("depends on: \(names.joined(separator: ", "))")
                            .font(AtelierFont.eyebrow)
                            .foregroundStyle(Color.atelierInkSecondary)
                            .lineLimit(2)
                    }
                }
            }
            if !draft.descriptionMd.isEmpty {
                Text(draft.descriptionMd)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInk.opacity(0.85))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func modelShortName(_ raw: String) -> String {
        ModelRouter.Model(rawValue: raw)?.displayName ?? raw
    }

    /// Maps a draft's dependency refs to the titles of sibling drafts (skipping
    /// any that were deleted from the review list).
    private func dependencyTitles(for draft: AIAssistant.TaskDraft) -> [String] {
        draft.dependsOnRefs.compactMap { ref in
            drafts.first(where: { $0.ref == ref })?.title
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .compose:
            HStack {
                Text("Opus 4.7")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(action: decompose) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text("Decompose").fontWeight(.semibold)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        case .running:
            HStack {
                Spacer()
                Button("Cancel") {
                    decomposeTask?.cancel()   // terminates the claude subprocess
                    phase = .compose          // keep the brief so they can retry/adjust
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        case .review:
            HStack {
                Button("Back to brief") { phase = .compose }
                    .controlSize(.small)
                Spacer()
                Button("Discard all", role: .destructive) {
                    drafts = []
                    phase = .compose
                }
                .controlSize(.small)
                Button(action: persistAll) {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 10))
                        Text("Create \(drafts.count) task\(drafts.count == 1 ? "" : "s")")
                            .fontWeight(.semibold)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(drafts.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    // MARK: Actions

    private func decompose() {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        error = nil
        phase = .running
        runningSince = Date()
        briefFocused = false
        let projectSnapshot = project
        let profile = ProjectProfile.find(id: project.profileId) ?? .generic
        let titles = store.tasks(in: project.id).map(\.title)
        let attachmentURLs = attachments
        let repoPath = inspectRepo ? project.path : nil
        activity.reset()
        let activityBox = activity
        let onActivity: @Sendable (String) async -> Void = { line in
            await MainActor.run { activityBox.push(line) }
        }
        decomposeTask = Task {
            do {
                let result = try await AIAssistant.decomposeBrief(
                    trimmed,
                    project: projectSnapshot,
                    profile: profile,
                    existingTitles: titles,
                    attachments: attachmentURLs,
                    repoPath: repoPath,
                    onActivity: onActivity
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    if result.isEmpty {
                        error = "Opus returned no tasks. Try a more concrete brief or a different framing."
                        phase = .compose
                    } else {
                        drafts = result
                        phase = .review
                    }
                }
            } catch {
                // User cancelled (or the sheet closed) — the Cancel action already
                // reset the UI; don't flash an error.
                if Task.isCancelled { return }
                await MainActor.run {
                    self.error = "Decomposition failed: \(error.localizedDescription)"
                    phase = .compose
                }
            }
        }
    }

    private func persistAll() {
        let snapshots = drafts
        saveError = nil
        Task {
            do {
                // Pass 1: create every task, recording its draft ref → real id so
                // we can wire dependencies once all ids exist.
                var refToId: [String: String] = [:]
                var created: [(draft: AIAssistant.TaskDraft, task: AtelierTask)] = []
                for draft in snapshots {
                    var task = try await store.createTask(
                        in: project,
                        title: draft.title,
                        priority: draft.priority,
                        workerModel: draft.workerModel
                    )
                    if !draft.descriptionMd.isEmpty { task.descriptionMd = draft.descriptionMd }
                    if !draft.labels.isEmpty { task.labels = draft.labels }
                    if !draft.descriptionMd.isEmpty || !draft.labels.isEmpty {
                        try await store.updateTask(task)
                    }
                    if let ref = draft.ref { refToId[ref] = task.id }
                    created.append((draft, task))
                }
                // Pass 2: resolve depends_on refs to real ids (drop self-refs and
                // any ref whose task was removed before persisting).
                for entry in created where !entry.draft.dependsOnRefs.isEmpty {
                    let deps = entry.draft.dependsOnRefs
                        .compactMap { refToId[$0] }
                        .filter { $0 != entry.task.id }
                    guard !deps.isEmpty else { continue }
                    var t = entry.task
                    t.dependsOn = Array(Set(deps))
                    try await store.updateTask(t)
                }
                await MainActor.run { onClose() }
            } catch {
                await MainActor.run {
                    saveError = "Could not persist tasks: \(error.localizedDescription)"
                }
            }
        }
    }
}
