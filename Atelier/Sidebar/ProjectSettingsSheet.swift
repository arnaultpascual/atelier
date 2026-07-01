// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Edit an existing project's settings. Two tabs:
///   - General: name, profile, default model, monthly budget
///   - Permissions: list / delete the project's `.atelier/config.yml` rules,
///     plus a read-only display of the profile's baked-in defaults.
///
/// Opened from the gear icon in the project header.
struct ProjectSettingsSheet: View {
    @Bindable var store: AppStore
    let project: Project
    let onClose: () -> Void

    @State private var selectedTab: Tab
    private let openToClaudeMd: Bool

    init(store: AppStore, project: Project, openToPermissions: Bool = false, openToClaudeMd: Bool = false, onClose: @escaping () -> Void) {
        self._store = Bindable(wrappedValue: store)
        self.project = project
        self.onClose = onClose
        self.openToClaudeMd = openToClaudeMd
        _selectedTab = State(initialValue: openToPermissions ? .permissions : .general)
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case general, permissions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "General"
            case .permissions: return "Permissions"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.atelierDivider).opacity(0.6)
            Group {
                switch selectedTab {
                case .general:
                    GeneralTab(store: store, project: project, scrollToClaudeMd: openToClaudeMd, onClose: onClose)
                case .permissions:
                    PermissionsTab(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(22)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 540, idealHeight: 620)
        .background(Color.atelierBackground)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.label)
                    .font(AtelierFont.callout.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.atelierAccent : Color.atelierInkSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.atelierAccentSoft.opacity(0.5) : .clear,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isSelected ? Color.atelierAccent.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @Bindable var store: AppStore
    let project: Project
    var scrollToClaudeMd: Bool = false
    let onClose: () -> Void

    @State private var draftName: String = ""
    @State private var draftProfileId: String = ProjectProfile.generic.id
    @State private var draftModel: String = "claude-sonnet-4-6"
    @State private var draftBudget: String = ""
    @State private var draftAutoApprove: AutoApproveLevel = .off
    @State private var draftBuildVerify: Bool = false
    @State private var draftBuildVerifyFinal: Bool = false
    @State private var draftVerifyCommand: String = ""
    @State private var draftCoverageRound: Bool = false
    @State private var saveError: String?
    @State private var savedOk: Bool = false
    @State private var toolchain: ToolchainChecker.Report?
    @State private var claudeMdState: ClaudeMdState = .idle
    @State private var claudeMdExists: Bool = false
    @State private var claudeMdDraft: String = ""        // editable copy of the drafted CLAUDE.md
    @State private var claudeMdRendered: Bool = true      // Preview (rendered) vs Edit (raw)
    @State private var showClaudeMdReview: Bool = false   // review in a roomy sheet, not the cramped pane
    @FocusState private var nameFocused: Bool

    private enum ClaudeMdState: Equatable {
        case idle
        case generating
        case preview(String)
        case savedOk
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        form
                        Divider().background(Color.atelierDivider).opacity(0.6)
                        claudeMdSection.id("claudemd")
                    }
                }
                .onAppear {
                    guard scrollToClaudeMd else { return }
                    // Opened via the CLAUDE.md pill — jump to that section and keep
                    // focus off the title field.
                    nameFocused = false
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("claudemd", anchor: .top)
                        }
                    }
                }
            }
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .onAppear {
            loadDraft()
            checkClaudeMd()
        }
        .task(id: draftProfileId) {
            let p = ProjectProfile.find(id: draftProfileId) ?? .generic
            guard !p.build.requiredTools.isEmpty else { toolchain = nil; return }
            toolchain = await ToolchainChecker.check(profile: p, projectPath: project.path)
        }
        .sheet(isPresented: $showClaudeMdReview) {
            ClaudeMdReviewSheet(
                markdown: $claudeMdDraft,
                rendered: $claudeMdRendered,
                exists: claudeMdExists,
                onSave: {
                    saveClaudeMd(claudeMdDraft)
                    showClaudeMdReview = false
                },
                onClose: { showClaudeMdReview = false }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Project settings")
                .font(AtelierFont.title)
                .foregroundStyle(Color.atelierInk)
            Text((project.path as NSString).abbreviatingWithTildeInPath)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("IDENTITY")
                .font(AtelierFont.eyebrow.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            field(label: "NAME") {
                TextField(project.name, text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            field(label: "MODE") {
                Picker("", selection: $draftProfileId) {
                    ForEach(ProjectProfile.catalog) { p in
                        Label(p.name, systemImage: p.iconSystemName).tag(p.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("A mode tailors decomposition, skills, build/test commands and permissions to the target platform.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                if let p = ProjectProfile.find(id: draftProfileId) {
                    Text(p.description)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                    modeBuildSummary(p)
                }
            }

            AtelierDivider().padding(.vertical, 2)
            Text("EXECUTION DEFAULTS")
                .font(AtelierFont.eyebrow.weight(.semibold))
                .foregroundStyle(Color.atelierInk)

            field(label: "DEFAULT MODEL") {
                Picker("", selection: $draftModel) {
                    ForEach(ModelRouter.Model.allCases, id: \.rawValue) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Used when a task doesn't pick its own model.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            field(label: "MONTHLY BUDGET (USD)") {
                HStack(spacing: 8) {
                    TextField("e.g. 50.00 — empty for none", text: $draftBudget)
                        .textFieldStyle(.roundedBorder)
                    if !draftBudget.isEmpty {
                        Button("Clear") { draftBudget = "" }
                            .controlSize(.small)
                    }
                }
                Text("Used by the Usage dashboard to flag when a project is burning its budget.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            field(label: "AUTO-APPROVE") {
                Picker("", selection: $draftAutoApprove) {
                    ForEach(AutoApproveLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(draftAutoApprove.blurb)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                if draftAutoApprove.isRisky {
                    CalloutBanner(.warning, draftAutoApprove == .all
                        ? "Agents run Bash and write files unattended. Worktree isolation still applies, but Bash can do anything you can — use only on work you trust."
                        : "Agents write and edit files unattended (Bash still asks).")
                }
            }

            field(label: "BUILD VERIFY BEFORE EACH MERGE") {
                Toggle(isOn: $draftBuildVerify) {
                    Text("Build the app before each task merge (opt-in, + fix)")
                        .font(AtelierFont.caption)
                }
                .toggleStyle(.switch)
                Text("Off by default — Atelier gates on unit tests + code review without building the app (a full build can need a device/target/remote step and take many minutes). Turn on only if a fast, local build target exists.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                if draftBuildVerify {
                    TextField(buildVerifyPlaceholder, text: $draftVerifyCommand)
                        .textFieldStyle(.roundedBorder)
                    Text(draftVerifyCommand.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Empty → uses the mode's build command\(modeBuildCommand.map { " (`\($0)`)" } ?? " (none — verification will be skipped)")."
                         : "Runs `\(draftVerifyCommand)` in the worktree before merge; on failure the worker iterates to fix.")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }

            field(label: "FINAL APP BUILD (+ FIX)") {
                Toggle(isOn: $draftBuildVerifyFinal) {
                    Text("Build once when all tasks are merged (opt-in, + fix pass)")
                        .font(AtelierFont.caption)
                }
                .toggleStyle(.switch)
                Text("Off by default. During the final synthesis (every task merged), builds the integration branch once and, on failure, iterates a fix worker (\"affinage\") — never a gate on unit tests. Uses the same command as above. Independent of the per-merge build.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            if let target = modeCoverageTarget {
                field(label: "COVERAGE IMPROVEMENT ROUND") {
                    Toggle(isOn: $draftCoverageRound) {
                        Text("Add a tests-first round when below the ≥ \(target)% aim (opt-in)")
                            .font(AtelierFont.caption)
                    }
                    .toggleStyle(.switch)
                    Text("Off by default. When the finished feature lands below \(target)% line coverage, the final synthesis pass spawns one tests-first round on the integration branch to raise it. Soft target — it never blocks a merge.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
        }
    }

    private var modeCoverageTarget: Int? {
        (ProjectProfile.find(id: draftProfileId) ?? .generic).build.coverageTarget
    }

    private var modeBuildCommand: String? {
        (ProjectProfile.find(id: draftProfileId) ?? .generic).build.buildCommand
    }
    private var buildVerifyPlaceholder: String {
        modeBuildCommand.map { "custom command — defaults to \($0)" } ?? "custom build command (e.g. ./gradlew :app:assembleDebug)"
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            content()
        }
    }

    /// Read-only summary of the mode's build/test commands, so the user sees what
    /// the strict TDD gate will run before merge.
    @ViewBuilder
    private func modeBuildSummary(_ p: ProjectProfile) -> some View {
        let b = p.build
        if b.buildCommand != nil || !b.testCommands.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let build = b.buildCommand {
                    summaryLine(icon: "hammer", text: build)
                }
                ForEach(b.testCommands) { tc in
                    summaryLine(icon: tc.tier == .fast ? "checkmark.seal" : "iphone",
                                text: tc.command,
                                trailing: tc.tier == .fast
                                    ? "gates review/merge"
                                    : (tc.requiresDevice ? "optional · needs device" : "optional"))
                }
                ToolchainReadinessView(profile: p, report: toolchain)
            }
            .padding(.top, 4)
        } else {
            Text("No build/test commands for this mode — TDD gating is informational.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
        }
    }

    private func summaryLine(icon: String, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Color.atelierInkSecondary)
            Text(text)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInk)
            if let trailing {
                Text("· \(trailing)")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let saveError {
                Text(saveError)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            } else if savedOk {
                Text("Saved.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.success)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(action: save) {
                Text("Save").fontWeight(.semibold)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
    }

    private var isValid: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if !draftBudget.isEmpty && parsedBudget == nil { return false }
        return true
    }

    private var parsedBudget: Double? {
        let trimmed = draftBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalised), v >= 0 else { return nil }
        return v
    }

    private func loadDraft() {
        draftName = project.name
        draftProfileId = project.profileId ?? ProjectProfile.generic.id
        draftModel = project.defaultModel ?? "claude-sonnet-4-6"
        draftBudget = project.budgetUsdMonthly.map { String(format: "%.2f", $0) } ?? ""
        draftAutoApprove = project.autoApproveLevel ?? .off
        draftBuildVerify = project.buildVerifyBeforeMerge
        draftBuildVerifyFinal = project.buildVerifyFinal
        draftVerifyCommand = project.verifyBuildCommand ?? ""
        draftCoverageRound = project.coverageImprovementRound
        saveError = nil
        savedOk = false
        // Open in read mode — user has to click the Name field to edit.
        nameFocused = false
    }

    private func save() {
        guard isValid else { return }
        var updated = project
        updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.profileId = draftProfileId
        updated.defaultModel = draftModel
        updated.budgetUsdMonthly = draftBudget.isEmpty ? nil : parsedBudget
        updated.autoApproveLevel = (draftAutoApprove == .off) ? nil : draftAutoApprove
        updated.buildVerifyBeforeMerge = draftBuildVerify
        updated.buildVerifyFinal = draftBuildVerifyFinal
        let cmd = draftVerifyCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.verifyBuildCommand = cmd.isEmpty ? nil : cmd
        updated.coverageImprovementRound = draftCoverageRound
        Task {
            do {
                try await store.updateProject(updated)
                await MainActor.run {
                    saveError = nil
                    savedOk = true
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    savedOk = false
                }
            }
        }
    }

    // MARK: CLAUDE.md generator

    private var claudeMdURL: URL {
        URL(fileURLWithPath: project.path).appendingPathComponent("CLAUDE.md")
    }

    private func checkClaudeMd() {
        claudeMdExists = FileManager.default.fileExists(atPath: claudeMdURL.path)
    }

    private var claudeMdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("CLAUDE.md")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Text(claudeMdExists ? "exists" : "missing")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(claudeMdExists ? Palette.success : Color.atelierInkSecondary)
            }
            Text("Per-project instructions Claude reads at session start. Atelier can draft one by scanning the repo with Haiku, then you review before saving.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .lineSpacing(2)
            claudeMdBody
        }
    }

    @ViewBuilder
    private var claudeMdBody: some View {
        switch claudeMdState {
        case .idle, .savedOk:
            HStack(spacing: 8) {
                Button(action: generateClaudeMd) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        Text(claudeMdExists ? "Regenerate with Haiku" : "Draft with Haiku")
                            .font(AtelierFont.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.atelierAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                if claudeMdExists {
                    Button(action: revealClaudeMd) {
                        Text("Reveal")
                            .font(AtelierFont.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if case .savedOk = claudeMdState {
                    Text("Saved to CLAUDE.md.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.success)
                }
            }
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Haiku is scanning the repo…")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
            }
        case .preview:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.success)
                Text("Draft ready (\(claudeMdDraft.count) chars) — review it in the editor.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Button("Discard") { claudeMdState = .idle }
                    .controlSize(.small)
                Button {
                    showClaudeMdReview = true
                } label: {
                    Text("Review & save").fontWeight(.semibold)
                }
                .controlSize(.small)
            }
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.error)
                Text(msg)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
                    .lineLimit(3)
                Spacer()
                Button("Retry") { generateClaudeMd() }
                    .controlSize(.small)
            }
        }
    }

    private func generateClaudeMd() {
        claudeMdState = .generating
        let projectName = project.name
        let projectPath = project.path
        let profile = ProjectProfile.find(id: project.profileId) ?? .generic
        Task {
            do {
                let md = try await AIAssistant.generateClaudeMd(
                    projectPath: projectPath,
                    projectName: projectName,
                    profile: profile
                )
                await MainActor.run {
                    claudeMdDraft = md
                    claudeMdRendered = true       // open in readable Preview by default
                    claudeMdState = .preview(md)
                    showClaudeMdReview = true      // pop the roomy review sheet
                }
            } catch {
                await MainActor.run { claudeMdState = .error(error.localizedDescription) }
            }
        }
    }

    private func saveClaudeMd(_ md: String) {
        do {
            try md.write(to: claudeMdURL, atomically: true, encoding: .utf8)
            checkClaudeMd()
            claudeMdState = .savedOk
        } catch {
            claudeMdState = .error("Could not write CLAUDE.md: \(error.localizedDescription)")
        }
    }

    private func revealClaudeMd() {
        guard FileManager.default.fileExists(atPath: claudeMdURL.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([claudeMdURL])
    }
}

// MARK: - Permissions tab

private struct PermissionsTab: View {
    let project: Project

    @State private var projectRules: [PermissionRule] = []
    @State private var lastError: String?
    @State private var newTool: String = ""
    @State private var newPattern: String = ""
    @State private var newReason: String = ""
    @State private var newBehavior: PermissionRule.Behavior = .deny

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permission rules")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Text("Project rules live in `\(configRelativePath)`. Profile defaults below are baked into Atelier and apply to every project of this profile.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            CalloutBanner(.info, "Autopilot mode auto-accepts every tool call EXCEPT the deny rules here — add deny rules to constrain what unattended agents may do. (The General tab's auto-approve level applies only to manual spawns.)", icon: "infinity")

            CalloutBanner(.warning, "Best-effort, not a hard boundary. Atelier gates every tool call through a hook and does its best to enforce these rules, but workers are AI — mistakes and edge cases happen. Treat this as a guardrail, keep sensitive paths on `deny`, and review anything that matters before trusting it unattended.")

            Divider().background(Color.atelierDivider).opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    projectRulesSection
                    profileRulesSection
                    Spacer(minLength: 8)
                }
            }
            if let lastError {
                Text(lastError)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }
        }
        .onAppear(perform: reload)
    }

    private var configRelativePath: String {
        "\(project.name)/.atelier/config.yml"
    }

    // MARK: Project rules (editable)

    private var projectRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROJECT RULES")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Text("\(projectRules.count) rule\(projectRules.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            if projectRules.isEmpty {
                Text("None yet — add one below, or use the ▼ next to Accept in the Approval inbox.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(projectRules.enumerated()), id: \.offset) { _, rule in
                        ruleRow(rule, editable: true)
                    }
                }
            }
            addRuleForm
        }
    }

    private var addRuleForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("ADD A RULE")
            HStack(spacing: 8) {
                Picker("", selection: $newBehavior) {
                    Text("deny").tag(PermissionRule.Behavior.deny)
                    Text("allow").tag(PermissionRule.Behavior.allow)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                TextField("tool — Bash, Read, * …", text: $newTool)
                    .textFieldStyle(.roundedBorder)
                TextField("pattern (optional) — *.swift, git push …", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addRule() }
                    .disabled(newTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("reason (optional)", text: $newReason)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
    }

    // MARK: Profile rules (read-only)

    private var profileRules: [PermissionRule] {
        (ProjectProfile.find(id: project.profileId) ?? .generic).defaultRules
    }

    private var profileRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROFILE DEFAULTS")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if let p = ProjectProfile.find(id: project.profileId) {
                    Text("· \(p.name)")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                }
                Spacer()
                Text("\(profileRules.count) rule\(profileRules.count == 1 ? "" : "s")")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Text("Read-only. To remove one, change the project profile or override with a deny rule above.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            VStack(spacing: 6) {
                ForEach(Array(profileRules.enumerated()), id: \.offset) { _, rule in
                    ruleRow(rule, editable: false)
                }
            }
        }
    }

    // MARK: Row renderer

    private func ruleRow(_ rule: PermissionRule, editable: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            behaviourBadge(rule.behavior)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.tool)
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierInk)
                    if let pat = rule.pattern, !pat.isEmpty {
                        Text(pat)
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(Color.atelierInkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if let reason = rule.reason, !reason.isEmpty {
                    Text(reason)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                        .lineLimit(2)
                }
            }
            Spacer()
            if editable {
                Button(role: .destructive) {
                    remove(rule)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.error)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this rule from \(configRelativePath)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(editable ? 0.8 : 0.4), lineWidth: 1))
    }

    @ViewBuilder
    private func behaviourBadge(_ behavior: PermissionRule.Behavior) -> some View {
        switch behavior {
        case .allow:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                Text("allow")
            }
            .font(AtelierFont.eyebrow)
            .foregroundStyle(Palette.success)
        case .deny:
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 11))
                Text("deny")
            }
            .font(AtelierFont.eyebrow)
            .foregroundStyle(Palette.error)
        }
    }

    // MARK: Actions

    private func reload() {
        projectRules = ProjectPermissionStore.loadRules(projectPath: project.path)
        lastError = nil
    }

    private func remove(_ rule: PermissionRule) {
        do {
            _ = try ProjectPermissionStore.removeRule(matching: rule, projectPath: project.path)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func addRule() {
        let tool = newTool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tool.isEmpty else { return }
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = newReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = PermissionRule(tool: tool,
                                  pattern: pattern.isEmpty ? nil : pattern,
                                  behavior: newBehavior,
                                  reason: reason.isEmpty ? nil : reason,
                                  scope: .project)
        do {
            try ProjectPermissionStore.appendRule(rule, projectPath: project.path)
            newTool = ""; newPattern = ""; newReason = ""
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - CLAUDE.md review sheet

/// A roomy window for reviewing / editing a drafted CLAUDE.md, instead of
/// cramming it into the settings pane. Preview renders the markdown; Edit gives
/// a raw editor; Save writes it.
private struct ClaudeMdReviewSheet: View {
    @Binding var markdown: String
    @Binding var rendered: Bool
    let exists: Bool
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            content
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .frame(minWidth: 760, idealWidth: 920, maxWidth: 1300,
               minHeight: 560, idealHeight: 760, maxHeight: 1200)
        .background(Color.atelierBackground)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAUDE.md")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierAccent)
                Text("Per-project instructions Claude reads at session start.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Picker("", selection: $rendered) {
                Text("Preview").tag(true)
                Text("Edit").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)
            Text("\(markdown.count) chars")
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if rendered {
            ScrollView {
                MarkdownView(source: markdown)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TextEditor(text: $markdown)
                .scrollContentBackground(.hidden)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.atelierInk)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if exists {
                Text("Will overwrite the existing CLAUDE.md.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.warning)
            }
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(action: onSave) {
                Text("Save to CLAUDE.md").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
