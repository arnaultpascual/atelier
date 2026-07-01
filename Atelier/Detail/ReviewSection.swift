// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Review banner for tasks in the Review column. Adapts to whatever the worker
/// produced:
/// - If there's text (analysis / recap / summary) → show it scrollable up top.
/// - If there's a code diff → show shortstat + worktree / merge / discard actions.
/// - Always: Discard + Mark as Done at the bottom.
struct ReviewSection: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
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
    @State private var runningTests: Bool = false
    @State private var generatingDossier: Bool = false
    @State private var dossierURL: URL?
    @State private var coverageRate: Double?       // 0…1, captured when a dossier is generated
    @State private var coverageRounding: Bool = false
    @State private var alignment: AIAssistant.AlignmentVerdict?
    @State private var reviewingAlignment: Bool = false
    @State private var buildVerifying: Bool = false
    @State private var buildVerifyResult: String?

    private struct PreviewItem: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let status: GitService.ChangeStatus
    }

    /// The three things you can look at for a finished worktree. One inspector,
    /// one selection — instead of three stacked panels fighting for the eye.
    private enum InspectorTab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case tests = "Tests"
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
            loadPersistedDossier()
            await refreshDiff()
            await loadDiskTranscript()
            await loadRunDuration()
        }
        .onChange(of: task.id) { _, _ in
            persistedReview = nil
            runDuration = nil
            loadPersistedReview()
            loadPersistedDossier()
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
            testStateChip(task.testState)
            integrityChip(task.testIntegrity)
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
        tabs.append(.tests)
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
                case .tests:        testsTab
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

    // MARK: Tests tab (strict-TDD gate)

    private var modeProfile: ProjectProfile { ProjectProfile.find(id: project.profileId) ?? .generic }

    /// Red/regressed tests OR a suspected test-weakening are a hard block on merge (and Mark as Done).
    /// The integrity block is overridable in the manual flow (Tests tab → "Trust test changes").
    /// Only the deterministic exit-code gate blocks merge. Test-change integrity is ADVISORY in the
    /// manual flow — surfaced + agent-reviewable, never a human-verification block.
    private var testsBlockMerge: Bool { task.testState.blocksMerge }

    @ViewBuilder
    private var testsTab: some View {
        let profile = modeProfile
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                testStateChip(task.testState)
                if task.testState == .unknown {
                    Text("Not run yet")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer(minLength: 0)
                if worktreeExists && !profile.build.fastTestCommands.isEmpty {
                    Button(action: runTestsNow) {
                        HStack(spacing: 4) {
                            if runningTests { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold)) }
                            Text(runningTests ? "Running…" : "Run tests").font(.system(.callout).weight(.medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    }
                    .buttonStyle(.plain).fixedSize().disabled(runningTests)
                    .help("Run the mode's test command in this worktree and update the gate.")
                }
            }

            // Opt-in build verification (on-demand). The default flow never builds the app.
            if worktreeExists, let buildCmd = project.resolvedVerifyBuildCommand(profile: profile) {
                HStack(spacing: 8) {
                    Button(action: buildVerifyNow) {
                        HStack(spacing: 4) {
                            if buildVerifying { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "hammer").font(.system(size: 10)) }
                            Text(buildVerifying ? "Building…" : "Build & verify").font(AtelierFont.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.atelierAccent)
                    }
                    .buttonStyle(.plain).disabled(buildVerifying).fixedSize()
                    .help("Run `\(buildCmd)` in this worktree to verify the build (can be slow). On-demand — not part of the default gate.")
                    Spacer()
                }
                if let r = buildVerifyResult {
                    noteRow(r.hasPrefix("Build OK") ? "checkmark.circle" : "exclamationmark.triangle", r,
                            color: r.hasPrefix("Build OK") ? Palette.success : Palette.warning)
                }
            }

            if profile.build.fastTestCommands.isEmpty {
                noteRow("minus.circle", "This mode has no test command — the TDD gate is informational and won't block merge. Set build/test commands on the mode to enable it.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.build.fastTestCommands.count > 1 ? "GATE COMMANDS" : "GATE COMMAND")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    ForEach(profile.build.fastTestCommands) { tc in
                        Text(tc.command)
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(Color.atelierInk)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
            }

            if let summary = task.testSummary, !summary.isEmpty {
                noteRow(testsBlockMerge ? "exclamationmark.triangle" : "checkmark.circle",
                        summary,
                        color: testsBlockMerge ? Palette.error : Color.atelierInkSecondary)
            }

            if task.testState.blocksMerge {
                CalloutBanner(.danger, "Tests are red — merge and Mark as Done are blocked. Iterate to fix, then Run tests to go green.")
            }

            if task.testIntegrity == .suspect || alignment != nil {
                testChangeReviewPanel
            } else if task.testIntegrity == .evolved {
                noteRow("checkmark.shield", "Tests evolved with the design (declared & accepted).")
            }

            Divider().background(Color.atelierDivider).opacity(0.5).padding(.vertical, 2)
            dossierRow
        }
    }

    // MARK: Test dossier (cahier de test)

    private var dossierRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CAHIER DE TEST")
                    .font(AtelierFont.eyebrow.weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                if worktreeExists {
                    Button(action: generateDossierNow) {
                        HStack(spacing: 4) {
                            if generatingDossier { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "doc.badge.gearshape").font(.system(size: 10)) }
                            Text(generatingDossier ? "Generating…" : (dossierURL == nil ? "Generate" : "Regenerate"))
                                .font(AtelierFont.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.atelierAccent)
                    }
                    .buttonStyle(.plain).disabled(generatingDossier)
                    .help("Write a two-part dossier: what's covered by tests vs. what a human must verify.")
                }
            }
            if let url = dossierURL {
                HStack(spacing: 8) {
                    Button("Download…") { downloadDossier() }.controlSize(.small)
                    Button("Reveal") { revealDossier() }.controlSize(.small)
                    Button("Copy") { copyDossier() }.controlSize(.small)
                    Spacer()
                }
                Text("Saved to .atelier/dossiers/\(task.id).md")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
            } else {
                Text("Two-part deliverable: Part A — covered by tests/code; Part B — manual QA checklist.")
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            }
            if let rate = coverageRate, let target = modeProfile.build.coverageTarget,
               rate * 100 + 0.05 < Double(target) {
                coverageProposal(rate: rate, target: target)
            }
        }
    }

    /// Non-blocking proposal shown when a generated dossier measured coverage below the mode's aim.
    /// Soft target: offers a tests-first round, never blocks anything.
    @ViewBuilder
    private func coverageProposal(rate: Double, target: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CalloutBanner(.info, "Coverage is \(String(format: "%.1f", rate * 100))%, below the ≥ \(target)% aim — a soft target that never blocks the merge. Add a round of tests?")
            Button(action: runCoverageRound) {
                HStack(spacing: 4) {
                    if coverageRounding { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 10)) }
                    Text(coverageRounding ? "Improving coverage…" : "Improve coverage")
                        .font(AtelierFont.caption.weight(.medium))
                }
                .foregroundStyle(Color.atelierAccent)
            }
            .buttonStyle(.plain).disabled(coverageRounding || !worktreeExists)
            .help("Resume the worker to add unit tests toward the aim, then re-run the gate and refresh the dossier.")
        }
    }

    private func loadPersistedDossier() {
        dossierURL = TestDossierStore.exists(taskId: task.id, projectPath: project.path)
            ? TestDossierStore.url(taskId: task.id, projectPath: project.path)
            : nil
    }

    private func generateDossierNow() {
        guard worktreeExists else { return }
        generatingDossier = true
        let profile = modeProfile
        let currentAlignment = alignment   // use an on-demand review if one was run; else DossierBuilder falls back to the task
        Task {
            let result = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: project.path, retriesOnRed: 0)
            // No app build here — stays build-independent. Use "Build & verify" on-demand if needed.
            let dossier = await DossierBuilder.build(
                task: task, profile: profile, project: project, branch: branch,
                worktreePath: worktreePath, testResult: result, buildOutcome: nil,
                review: nil, alignment: currentAlignment, apiKey: APIKeyResolver.resolve())
            let url = TestDossierStore.persist(dossier, projectPath: project.path)
            // DossierBuilder.build just ran the coverage command (if the mode has one) — read the
            // numeric rate it wrote, to drive the soft coverage-round proposal below.
            let rate = DossierBuilder.coverageLineRate(worktreePath: worktreePath)
            await MainActor.run {
                dossierURL = url
                coverageRate = rate
                generatingDossier = false
            }
        }
    }

    /// Spawns a tests-first round (resuming the task's session) to raise coverage toward the mode's
    /// aim, then re-runs the gate, re-measures, and regenerates the dossier. Soft target — the task
    /// stays where it is; this is polish, never a retroactive block.
    private func runCoverageRound() {
        guard worktreeExists, !coverageRounding,
              let target = modeProfile.build.coverageTarget else { return }
        coverageRounding = true
        let profile = modeProfile
        let current = (coverageRate ?? 0) * 100
        Task {
            guard let prior = try? await store.agentsForTask(task.id).first,
                  prior.sessionId?.isEmpty == false else {
                await MainActor.run { coverageRounding = false }
                return
            }
            _ = await spawner.iterateAndAwait(
                task: task, project: project, priorAgent: prior,
                message: coverageRoundMessage(current: current, target: target),
                apiKey: APIKeyResolver.resolve(), store: store, server: server,
                approvalQueue: approvalQueue, autopilot: false)
            // Keep the gate honest: re-run tests after the round, then refresh coverage + dossier.
            let result = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: project.path)
            if var t = await store.freshTask(task.id) {
                t.testState = result.toolchainMissing ? .toolchainMissing : (result.passed ? .green : .red)
                t.testSummary = result.summaryLine
                try? await store.updateTask(t)
            }
            await MainActor.run {
                coverageRounding = false
                generateDossierNow()   // re-measures coverage + rewrites the dossier (main-actor @State)
            }
        }
    }

    private func coverageRoundMessage(current: Double, target: Int) -> String {
        """
        Coverage on this task is \(String(format: "%.1f", current))%, below the \(target)% aim. Add
        UNIT TESTS ONLY to raise it toward \(target)% — prioritise the least-covered, highest-risk
        paths (error handling, edge cases, branches). Meaningful assertions only, never placeholder
        tests, and don't weaken any existing test. Keep the suite green. This is a soft target, not a
        gate — get as close as you reasonably can. Commit when done.
        """
    }

    private func downloadDossier() {
        guard let url = dossierURL, let md = try? String(contentsOf: url, encoding: .utf8) else { return }
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") { panel.allowedContentTypes = [mdType] }
        panel.nameFieldStringValue = "cahier-de-test-\(BacklogMD.slugify(task.title)).md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            try? md.write(to: dest, atomically: true, encoding: .utf8)
        }
    }

    private func revealDossier() {
        guard let url = dossierURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyDossier() {
        guard let url = dossierURL, let md = try? String(contentsOf: url, encoding: .utf8) else { return }
        copyToPasteboard(md)
    }

    private func runTestsNow() {
        guard worktreeExists else { return }
        runningTests = true
        let profile = modeProfile
        Task {
            let result = await TestRunner.runFastTests(profile: profile, worktreePath: worktreePath, mainRepoPath: project.path)
            var updated = task
            if profile.build.fastTestCommands.isEmpty {
                updated.testState = .noTests
                updated.testSummary = nil
            } else if result.toolchainMissing {
                updated.testState = .toolchainMissing
                updated.testSummary = result.summaryLine
            } else {
                updated.testState = result.passed ? .green : .red
                updated.testSummary = result.summaryLine
            }
            try? await store.updateTask(updated)
            await MainActor.run { runningTests = false }
        }
    }

    /// On-demand build verification (opt-in flow; the default gate never builds the app).
    private func buildVerifyNow() {
        guard worktreeExists, let command = project.resolvedVerifyBuildCommand(profile: modeProfile) else { return }
        buildVerifying = true
        Task {
            let outcome = await TestRunner.runCommand(command, worktreePath: worktreePath, profile: modeProfile, mainRepoPath: project.path)
            let summary: String
            if let o = outcome {
                if o.passed {
                    summary = "Build OK — `\(command)`"
                } else {
                    let tail = o.stderrTail.isEmpty ? o.stdoutTail : o.stderrTail
                    summary = "Build failed (exit \(o.exitCode)) — \(String(tail.suffix(160)))"
                }
            } else {
                summary = "Couldn't run the build command."
            }
            await MainActor.run {
                buildVerifyResult = summary
                buildVerifying = false
            }
        }
    }

    @ViewBuilder
    private func testStateChip(_ s: AtelierTask.TestState) -> some View {
        if let m = testStateMeta(s) {
            HStack(spacing: 4) {
                Image(systemName: m.icon).font(.system(size: 9, weight: .semibold))
                Text(m.label).font(AtelierFont.eyebrow)
            }
            .foregroundStyle(m.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(m.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(m.color.opacity(0.3), lineWidth: 1))
            .help(task.testSummary ?? m.label)
        }
    }

    private func testStateMeta(_ s: AtelierTask.TestState) -> (label: String, icon: String, color: Color)? {
        switch s {
        case .unknown:     return nil
        case .green:       return ("Tests green", "checkmark.seal.fill", Palette.success)
        case .greenMerged: return ("Tests green", "checkmark.seal.fill", Palette.success)
        case .red:         return ("Tests red", "xmark.octagon.fill", Palette.error)
        case .regressed:   return ("Regressed", "exclamationmark.triangle.fill", Palette.error)
        case .noTests:     return ("No tests", "minus.circle", Color.atelierInkSecondary)
        case .toolchainMissing: return ("Toolchain missing", "wrench.and.screwdriver.fill", Palette.warning)
        }
    }

    @ViewBuilder
    private func integrityChip(_ i: AtelierTask.TestIntegrity) -> some View {
        if let m = integrityMeta(i) {
            HStack(spacing: 4) {
                Image(systemName: m.icon).font(.system(size: 9, weight: .semibold))
                Text(m.label).font(AtelierFont.eyebrow)
            }
            .foregroundStyle(m.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(m.color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(m.color.opacity(0.3), lineWidth: 1))
            .help(task.testChangeNote ?? m.label)
        }
    }

    private func integrityMeta(_ i: AtelierTask.TestIntegrity) -> (label: String, icon: String, color: Color)? {
        switch i {
        case .unevaluated, .intact: return nil
        case .evolved:  return ("Tests evolved", "shield.lefthalf.filled", Color.atelierAccent)
        case .suspect:  return ("Tests weakened?", "exclamationmark.shield.fill", Palette.warning)
        }
    }

    /// Advisory panel for changed/weakened tests. No merge block — offers an on-demand agent review
    /// ("was the change necessary? does it still answer the demand?") and a human "mark as fine".
    @ViewBuilder
    private var testChangeReviewPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            CalloutBanner(.warning, "Test changes detected\(task.testChangeNote == nil ? " (no ## TEST-CHANGES declaration)" : ""). Not blocking — review whether the change was necessary and still answers the demand.")
            if let note = task.testChangeNote, !note.isEmpty {
                Text("Worker's declared rationale")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                Text(note).font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled).lineLimit(8)
            }
            if let a = alignment {
                noteRow(a.aligned ? "checkmark.seal" : "exclamationmark.triangle",
                        "\(a.aligned ? "Aligned" : "Needs rework"): \(a.rationale)",
                        color: a.aligned ? Palette.success : Palette.warning)
                if !a.aligned, !a.fixInstructions.isEmpty {
                    Text("Suggested fix (use Iterate to apply):")
                        .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    Text(a.fixInstructions).font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                        .textSelection(.enabled).lineLimit(10)
                }
            }
            HStack(spacing: 8) {
                if worktreeExists {
                    Button(action: reviewAlignmentNow) {
                        HStack(spacing: 4) {
                            if reviewingAlignment { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "checkmark.seal").font(.system(size: 10)) }
                            Text(reviewingAlignment ? "Reviewing…" : "Review test changes with agent")
                                .font(.system(.callout).weight(.medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    }
                    .buttonStyle(.plain).disabled(reviewingAlignment).fixedSize()
                    .help("Ask an agent: was the test change necessary, and does the implementation still answer the demand?")
                }
                Button("Mark as fine") { markTestsFine() }
                    .controlSize(.small)
                    .help("Record these test changes as a legitimate design evolution.")
                Spacer()
            }
        }
    }

    private func reviewAlignmentNow() {
        guard worktreeExists else { return }
        reviewingAlignment = true
        let profile = modeProfile
        Task {
            let signals = await TestIntegrityChecker.inspect(profile: profile, projectPath: project.path,
                                                             branch: branch, taskId: task.id)
            let note = TestIntegrityChecker.declaredNote(worktreePath: worktreePath, taskId: task.id)
            // The reviewer runs `git diff <base>...HEAD` in the worktree — pass the real merge-base,
            // not "HEAD" (which would diff nothing).
            let base = await GitService.mergeBaseRef(projectPath: project.path, branch: branch)
            let v = try? await AIAssistant.reviewTestAlignment(
                taskTitle: task.title, brief: task.descriptionMd ?? "", globalContext: nil,
                testDiff: signals.diffText, declaredNote: note, mechanicalSummary: signals.summaryLine,
                worktreePath: worktreePath, baseBranch: base, apiKey: APIKeyResolver.resolve())
            await MainActor.run {
                alignment = v
                reviewingAlignment = false
            }
            if let v, v.aligned {
                var updated = task
                updated.testIntegrity = .evolved
                try? await store.updateTask(updated)
            }
        }
    }

    private func markTestsFine() {
        var updated = task
        updated.testIntegrity = .evolved
        Task { try? await store.updateTask(updated) }
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
                    .disabled(testsBlockMerge)
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
            .disabled(merging || testsBlockMerge)
            .help(testsBlockMerge
                  ? "Blocked: tests are red. Fix them (Tests tab → Run tests) before merging."
                  : "Merge worktree-\(task.id) into your current branch (--no-ff), mark the task Done, and remove the worktree. Conflicts abort cleanly so you can resolve by hand.")

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


    /// Merge the task's worktree branch into the project's current branch with `--no-ff` (the same
    /// plumbing autopilot uses), then mark the task Done and remove the worktree. If the current
    /// branch is protected (main / develop / …), it does NOT merge — it offers to create a feature
    /// branch first. A conflict aborts cleanly and points the user at the copyable command.
    private func mergeInApp() {
        guard !testsBlockMerge else {
            mergeError = "Tests are red — fix and re-run (Tests tab → Run tests) before merging."
            return
        }
        merging = true
        mergeError = nil
        Task {
            do {
                let base = try await GitService.currentBranch(projectPath: project.path)
                if GitService.protectedBranches.contains(base.lowercased()) {
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
