// SPDX-License-Identifier: MIT
import SwiftUI

/// Inspector content for a selected task. Header (id + title + meta) at top,
/// compact metadata pickers below, big multi-line description editor that flexes
/// to fill the remaining height, sticky action footer.
struct TaskDetailView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    let task: AtelierTask
    let selectedProject: Project?
    let onClear: () -> Void

    @State private var editingTitle: String = ""
    @State private var editingDescription: String = ""
    @State private var editingStatus: AtelierTask.Status = .toDo
    @State private var editingPriority: AtelierTask.Priority?
    @State private var editingWorkerModel: String?       // nil = Auto
    @State private var editingBudgetUsd: String = ""
    @State private var editingDependsOn: Set<String> = []
    @State private var dirty: Bool = false
    @State private var saveError: String?
    @State private var suggestionState: SuggestionState = .idle
    @State private var improveState: ImproveState = .idle
    @State private var improveReview: ImproveReview?
    @State private var iterating: Bool = false
    @State private var taskUsage: TaskUsage?
    @FocusState private var titleFocused: Bool

    private struct TaskUsage: Equatable {
        var runs: Int
        var cost: Double
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var tokens: Int { input + output + cacheRead + cacheCreation }
    }

    private enum SuggestionState: Equatable {
        case idle
        case loading
        case suggested(model: String, reason: String)
        case error(String)
    }
    private enum ImproveState: Equatable {
        case idle
        case loading
        case error(String)
    }

    private struct ImproveReview: Identifiable, Equatable {
        let id = UUID()
        let original: String
        let improved: String
    }

    var body: some View {
        Group {
            if iterating, let project = selectedProject {
                IterateView(store: store,
                            spawner: spawner,
                            server: server,
                            approvalQueue: approvalQueue,
                            task: task,
                            project: project,
                            onExit: { iterating = false })
            } else {
                detailBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.atelierBackground)
        .onAppear(perform: load)
        .onChange(of: task.id) { _, _ in load() }
        .task(id: task.id) { await loadUsage() }
        .sheet(item: $improveReview) { review in
            ImproveReviewSheet(
                original: review.original,
                improved: review.improved,
                onApply: {
                    editingDescription = review.improved
                    dirty = true
                    improveReview = nil
                },
                onDismiss: { improveReview = nil }
            )
        }
    }

    private var detailBody: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    AtelierDivider()
                }

            if isLockedForReview {
                lockedReviewBody
            } else {
                editableBody
            }
        }
    }

    private var isLockedForReview: Bool {
        task.status == .review || task.status == .done
    }

    // MARK: Editable body (To Do / In Progress / Blocked)

    private var editableBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Left rail — how the task runs, what it waits on, what it has cost.
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        metadata
                        if (taskUsage?.runs ?? 0) > 0 {
                            taskCostStrip
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 320)

                Rectangle().fill(Color.atelierDivider.opacity(0.6)).frame(width: 1)

                // Main column — attachments, optional autopilot review, then the prompt editor (fills).
                VStack(alignment: .leading, spacing: 0) {
                    AttachmentsSection(store: store, task: task)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) { AtelierDivider() }

                    autopilotReportSection

                    descriptionEditor
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    AtelierDivider()
                }
                .background(Color.atelierBackground)
        }
    }

    // MARK: Locked review body

    private var lockedReviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CalloutBanner(.warning, "Locked while in Review — move the task back to To Do to edit the brief.")
                    .padding(.horizontal, 36)
                    .padding(.top, 14)
                if let project = selectedProject {
                    ReviewSection(store: store,
                                  spawner: spawner,
                                  task: task,
                                  project: project,
                                  onIterate: { iterating = true })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                        .overlay(alignment: .bottom) {
                            AtelierDivider()
                        }
                }

                if (taskUsage?.runs ?? 0) > 0 {
                    taskCostStrip
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            AtelierDivider()
                        }
                }

                statusOnlyRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        AtelierDivider()
                    }

                autopilotReportSection

                briefDisclosure
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        AtelierDivider()
                    }

                lockedFooter
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var statusOnlyRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            metaColumn("STATUS") {
                Picker("", selection: $editingStatus) {
                    ForEach(AtelierTask.Status.kanbanOrder, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: editingStatus) { _, newValue in
                    guard newValue != task.status else { return }
                    Task { try? await store.updateTaskStatus(task, to: newValue) }
                }
            }
            Spacer()
        }
    }

    @State private var briefExpanded: Bool = false
    @State private var autopilotExpanded: Bool = false

    private var briefDisclosure: some View {
        DisclosureGroup(isExpanded: $briefExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !task.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(task.labels, id: \.self) { l in
                            Text(l)
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Color.atelierInkSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.atelierSurface, in: Capsule())
                                .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                        }
                    }
                }
                Text(task.descriptionMd ?? "(no description)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.justify").font(.system(size: 10))
                Text("Original brief")
                    .font(AtelierFont.eyebrow)
                Text("\((task.descriptionMd ?? "").count) chars")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
            }
            .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    // MARK: Autopilot report (persisted by FeatureBuildRunner)

    /// Shows the autopilot's per-task report (review verdict + findings + outcome) when the run
    /// wrote one to `<project>/.atelier/autopilot/<taskId>.md`. Renders nothing otherwise, so it's
    /// invisible for manually-run tasks.
    @ViewBuilder
    private var autopilotReportSection: some View {
        if let md = autopilotReportMarkdown() {
            DisclosureGroup(isExpanded: $autopilotExpanded) {
                Text(md)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "infinity").font(.system(size: 10))
                    Text("Autopilot review").font(AtelierFont.eyebrow)
                    Spacer()
                }
                .foregroundStyle(Color.atelierAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                AtelierDivider()
            }
        }
    }

    private func autopilotReportMarkdown() -> String? {
        guard let project = selectedProject else { return nil }
        let url = URL(fileURLWithPath: project.path).appendingPathComponent(".atelier/autopilot/\(task.id).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private var lockedFooter: some View {
        HStack {
            Button(role: .destructive) {
                Task {
                    try? await store.deleteTask(task)
                    onClear()
                }
            } label: {
                Text("Delete task")
                    .font(.system(.callout))
                    .foregroundStyle(Palette.error)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .fixedSize()
            Spacer()
            Text("Editing locked — move the task back to To Do to change the brief.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.id)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if dirty {
                    Text("· unsaved")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierAccent)
                }
                Spacer()
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close detail")
            }
            if isLockedForReview {
                // Locked: render as plain text so macOS can't auto-focus +
                // select-all the field when the inspector appears.
                Text(editingTitle.isEmpty ? "Untitled task" : editingTitle)
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Untitled task", text: $editingTitle, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onChange(of: editingTitle) { _, _ in dirty = true }
            }
            Text("Updated \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row 1: status + priority side-by-side (short labels fit in narrow inspector)
            HStack(alignment: .top, spacing: 14) {
                metaColumn("STATUS") {
                    Picker("", selection: $editingStatus) {
                        ForEach(AtelierTask.Status.kanbanOrder, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: editingStatus) { _, _ in dirty = true }
                }
                metaColumn("PRIORITY") {
                    Picker("", selection: Binding(
                        get: { editingPriority },
                        set: { editingPriority = $0; dirty = true }
                    )) {
                        Text("—").tag(Optional<AtelierTask.Priority>.none)
                        ForEach(AtelierTask.Priority.allCases, id: \.self) { p in
                            Text(p.displayName).tag(Optional(p))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            // Row 2: model picker on its own row (full width — labels are longer)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MODEL")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                    suggestButton
                }
                Picker("", selection: Binding(
                    get: { editingWorkerModel ?? "auto" },
                    set: { newValue in
                        editingWorkerModel = newValue == "auto" ? nil : newValue
                        dirty = true
                        if case .suggested = suggestionState { suggestionState = .idle }
                    }
                )) {
                    Text("Auto — Atelier picks at spawn").tag("auto")
                    Divider()
                    ForEach(ModelRouter.Model.allCases, id: \.rawValue) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                suggestionPanel
            }

            // Row 3: optional per-task budget cap in USD. Currently advisory —
            // shown in the task sheet and tooltip; spawn-time enforcement
            // lands in a follow-up slice once we wire cost-monitoring back
            // through the worker stream.
            VStack(alignment: .leading, spacing: 5) {
                Text("MAX COST (USD) — OPTIONAL")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                TextField("e.g. 1.00 — empty = no cap",
                          text: $editingBudgetUsd)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: editingBudgetUsd) { _, _ in dirty = true }
                Text("Hard cap. The worker is SIGTERM'd as soon as `total_cost_usd` crosses this value. Leave empty for no cap.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            // Row 4: dependencies — the lever for organizing tasks into batches (rounds).
            dependsOnEditor
        }
    }

    // MARK: Dependencies (batch organization)

    /// Pick which other tasks must finish before this one — this is what assigns a task to a
    /// later batch/round. No dependencies → it runs in round 1.
    private var dependsOnEditor: some View {
        let all = selectedProject.map { store.tasks(in: $0.id) } ?? []
        let others = all.filter { $0.id != task.id }
        let roundOf = dependencyRoundMap(all: all)
        let cycles = editingDependsOn.intersection(dependentsClosure(of: task.id, in: all))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("DEPENDS ON")
                Spacer()
                if !editingDependsOn.isEmpty {
                    Text("\(editingDependsOn.count) selected")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                }
            }
            if !cycles.isEmpty {
                CalloutBanner(.danger, "Cycle: \(cycles.sorted().joined(separator: ", ")) already wait on this task. Uncheck to keep the graph runnable.")
            }
            if others.isEmpty {
                Text("No other tasks yet — add more, then pick which must finish first.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(others) { other in
                            Toggle(isOn: dependencyBinding(other.id)) {
                                HStack(spacing: 6) {
                                    Text(other.id)
                                        .font(AtelierFont.eyebrow)
                                        .foregroundStyle(Color.atelierInkSecondary)
                                    if let r = roundOf[other.id] {
                                        Text("R\(r)")
                                            .font(AtelierFont.eyebrow)
                                            .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.atelierSurface, in: Capsule())
                                            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                                    }
                                    Text(other.title)
                                        .font(AtelierFont.caption)
                                        .foregroundStyle(Color.atelierInk)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                Text("Tasks you depend on must reach Done before this one runs — that's what moves it into a later batch. No dependencies = round 1.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
    }

    /// Round (execution wave) of each To-Do task, so the checklist can show where a dependency lands.
    private func dependencyRoundMap(all: [AtelierTask]) -> [String: Int] {
        let todo = all.filter { $0.status == .toDo }
        var m: [String: Int] = [:]
        for w in ExecutionPlanner.waves(tasks: todo, allTasks: all) {
            for t in w.tasks { m[t.id] = w.round }
        }
        return m
    }

    /// Tasks that (transitively) depend on `id` — selecting any of these as a dependency would
    /// form a cycle.
    private func dependentsClosure(of id: String, in all: [AtelierTask]) -> Set<String> {
        var result: Set<String> = []
        var frontier = [id]
        while let cur = frontier.popLast() {
            for t in all where t.dependsOn.contains(cur) && !result.contains(t.id) {
                result.insert(t.id); frontier.append(t.id)
            }
        }
        return result
    }

    private func dependencyBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { editingDependsOn.contains(id) },
            set: { on in
                if on { editingDependsOn.insert(id) } else { editingDependsOn.remove(id) }
                dirty = true
            }
        )
    }

    @ViewBuilder
    private func metaColumn<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(label)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestButton: some View {
        Button(action: requestSuggestion) {
            HStack(spacing: 4) {
                if case .loading = suggestionState {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                }
                Text(suggestionState == .loading ? "Asking Haiku…" : "Suggest")
                    .font(AtelierFont.caption.weight(.medium))
            }
            .foregroundStyle(Color.atelierInkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(suggestionState == .loading)
        .help("Ask Haiku 4.5 to pick a model based on this task's title, description and labels.")
    }

    @ViewBuilder
    private var suggestionPanel: some View {
        switch suggestionState {
        case .idle:
            if editingWorkerModel == nil {
                Text("Atelier picks at spawn time — Opus 4.7 for refactors, Haiku for chores, Sonnet/Opus 4.6 otherwise.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.top, 4)
            }
        case .loading:
            EmptyView()
        case .suggested(let model, let reason):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.atelierAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended: \(prettyModelName(model))")
                        .font(AtelierFont.caption.weight(.semibold))
                        .foregroundStyle(Color.atelierInk)
                    Text(reason)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .lineSpacing(1)
                }
                Spacer()
                Button("Apply") {
                    editingWorkerModel = model
                    dirty = true
                    suggestionState = .idle
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    suggestionState = .idle
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.atelierAccentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 6)
        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(msg).font(AtelierFont.caption)
                Spacer()
                Button {
                    suggestionState = .idle
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.error)
            .padding(.top, 4)
        }
    }

    private func prettyModelName(_ raw: String) -> String {
        ModelRouter.Model(rawValue: raw)?.displayName ?? raw
    }

    // MARK: Description

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("DESCRIPTION & PROMPT")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                improveButton
                Spacer()
                Text("\(editingDescription.count) chars")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            }
            TextEditor(text: $editingDescription)
                .scrollContentBackground(.hidden)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.atelierInk)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                .overlay(
                    RoundedRectangle(cornerRadius: AtelierCorner.control)
                        .stroke(Color.atelierDivider, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if editingDescription.isEmpty {
                        Text("What should the worker do?\n\nUse markdown — sections like `## Plan`, `## Notes`, `## Acceptance criteria` are conventional.\n\nThis whole body is appended to the prompt at spawn time.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.atelierInkSecondary.opacity(0.55))
                            .padding(18)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: editingDescription) { _, _ in dirty = true }
            improvePanel
        }
    }

    private var improveButton: some View {
        Button(action: requestImprove) {
            HStack(spacing: 4) {
                if case .loading = improveState {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                }
                Text(improveState == .loading ? "Improving…" : "Improve")
                    .font(AtelierFont.caption.weight(.medium))
            }
            .foregroundStyle(Color.atelierInkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(improveState == .loading || editingDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Ask Haiku 4.5 to rewrite this description for clarity. Preserves your intent, adds structure.")
    }

    @ViewBuilder
    private var improvePanel: some View {
        if case .error(let msg) = improveState {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text(msg).font(AtelierFont.caption).lineLimit(2)
                Spacer()
                Button { improveState = .idle } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.error)
            .padding(.top, 6)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Text(saveError)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }
            HStack(spacing: 10) {
                spawnButton.fixedSize()
                Spacer()
                Button(role: .destructive) {
                    Task {
                        try? await store.deleteTask(task)
                        onClear()
                    }
                } label: {
                    Text("Delete")
                        .font(.system(.callout))
                        .foregroundStyle(Palette.error)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .fixedSize()

                Button(action: save) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Save")
                            .font(.system(.callout).weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(dirty ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                }
                .buttonStyle(.plain)
                .disabled(!dirty)
                .keyboardShortcut("s", modifiers: [.command])
                .fixedSize()
            }
        }
    }

    // MARK: Spawn

    @ViewBuilder
    private var spawnButton: some View {
        let isReady = canSpawnIgnoringDirty
        Button(action: { if dirty { saveAndSpawn() } else { spawnWorker() } }) {
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: 10))
                Text(dirty ? "Save & Spawn" : "Spawn")
                    .font(.system(.callout).weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(isReady ? .white : Color.atelierInkSecondary)
            .background(
                isReady
                    ? Color.atelierAccent
                    : Color.atelierSurface,
                in: RoundedRectangle(cornerRadius: AtelierCorner.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AtelierCorner.control)
                    .stroke(isReady ? Color.clear : Color.atelierDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .help(spawnHelpText)
    }

    /// Spawnable ignoring unsaved edits — used to enable "Save & Spawn" (which saves first).
    private var canSpawnIgnoringDirty: Bool {
        guard let project = selectedProject else { return false }
        if !server.helperReady { return false }
        if spawner.hasLiveWorker(for: task.id) { return false }
        return FileManager.default.fileExists(atPath: project.path)
    }

    private var canSpawn: Bool {
        canSpawnIgnoringDirty && !dirty
    }

    private var spawnHelpText: String {
        if selectedProject == nil { return "Select a project first." }
        if !server.helperReady { return "MCP helper binary missing — rebuild the app." }
        if spawner.hasLiveWorker(for: task.id) { return "A worker is already running on this task." }
        if dirty { return "Saves your unsaved edits, then spawns a worker in a git worktree." }
        return "Spawn a claude worker on this task. A git worktree is created under `.atelier-worktrees/\(task.id)/`."
    }

    private func spawnWorker() {
        guard let project = selectedProject else { return }
        spawner.start(
            task: task,
            project: project,
            apiKey: APIKeyResolver.resolve(),
            store: store,
            server: server,
            approvalQueue: approvalQueue
        )
    }

    // MARK: Actions

    private func requestSuggestion() {
        var snapshot = task
        snapshot.title = editingTitle
        snapshot.descriptionMd = editingDescription.isEmpty ? nil : editingDescription
        snapshot.priority = editingPriority

        suggestionState = .loading
        Task {
            do {
                let suggestion = try await AIAssistant.suggestModel(forTask: snapshot, apiKey: nil)
                await MainActor.run {
                    suggestionState = .suggested(model: suggestion.model.rawValue, reason: suggestion.reason)
                }
            } catch {
                await MainActor.run {
                    suggestionState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func requestImprove() {
        let trimmed = editingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var snapshot = task
        snapshot.title = editingTitle
        snapshot.descriptionMd = trimmed
        let originalAtRequestTime = editingDescription   // capture for diff view
        improveState = .loading
        Task {
            do {
                let improved = try await AIAssistant.improveDescription(
                    forTask: snapshot,
                    currentDescription: trimmed,
                    apiKey: nil
                )
                await MainActor.run {
                    improveState = .idle
                    improveReview = ImproveReview(original: originalAtRequestTime, improved: improved)
                }
            } catch {
                await MainActor.run {
                    improveState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func load() {
        editingTitle = task.title
        editingDescription = task.descriptionMd ?? ""
        editingStatus = task.status
        editingPriority = task.priority
        editingWorkerModel = task.workerModel
        editingBudgetUsd = task.budgetUsd.map { String(format: "%.2f", $0) } ?? ""
        editingDependsOn = Set(task.dependsOn)
        dirty = false
        saveError = nil
        suggestionState = .idle
        improveState = .idle
        improveReview = nil
        // Open in read mode: the user has to click the field to edit. Prevents
        // the macOS sheet auto-focus + select-all on the title field.
        titleFocused = false
    }

    private func loadUsage() async {
        guard let agents = try? await store.agentsForTask(task.id), !agents.isEmpty else {
            taskUsage = nil
            return
        }
        var u = TaskUsage(runs: 0, cost: 0, input: 0, output: 0, cacheRead: 0, cacheCreation: 0)
        for a in agents {
            u.runs += 1
            u.cost += a.costUsd
            u.input += a.inputTokens
            u.output += a.outputTokens
            u.cacheRead += a.cacheReadTokens
            u.cacheCreation += a.cacheCreationTokens
        }
        taskUsage = u
    }

    /// Cost + token totals for this task's worker run(s). `$` is the exact
    /// `total_cost_usd` summed across runs — API-equivalent on Pro/Max.
    @ViewBuilder
    private var taskCostStrip: some View {
        if let u = taskUsage, u.runs > 0 {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 11))
                    Text(String(format: "$%.4f", u.cost))
                        .font(AtelierFont.captionMono.weight(.semibold))
                }
                .foregroundStyle(Color.atelierAccent)
                .help("Sum of total_cost_usd across this task's run(s). On Pro/Max this is the API-equivalent cost — your subscription is a flat fee.")

                Text("\(formatTokenCount(u.tokens)) tok")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .help("in \(formatTokenCount(u.input)) · out \(formatTokenCount(u.output)) · cache \(formatTokenCount(u.cacheRead + u.cacheCreation))")

                if u.runs > 1 {
                    Text("· \(u.runs) runs")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                }
                Spacer()
                Text("API-EQUIV")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            }
        }
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func buildUpdatedTask() -> AtelierTask {
        var updated = task
        updated.title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.title.isEmpty { updated.title = "Untitled task" }
        updated.descriptionMd = editingDescription.isEmpty ? nil : editingDescription
        updated.status = editingStatus
        updated.priority = editingPriority
        updated.workerModel = editingWorkerModel
        let trimmedBudget = editingBudgetUsd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBudget.isEmpty {
            updated.budgetUsd = nil
        } else if let v = Double(trimmedBudget.replacingOccurrences(of: ",", with: ".")), v >= 0 {
            updated.budgetUsd = v
        }
        updated.dependsOn = Array(editingDependsOn).sorted()
        return updated
    }

    private func save() {
        guard dirty else { return }
        let updated = buildUpdatedTask()
        Task {
            do {
                try await store.updateTask(updated)
                dirty = false
                saveError = nil
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Save any pending edits, then spawn a worker on the freshly-saved task, so the worker
    /// always reads the prompt you see — in one click.
    private func saveAndSpawn() {
        guard let project = selectedProject else { return }
        let updated = buildUpdatedTask()
        Task {
            do {
                try await store.updateTask(updated)
                dirty = false
                saveError = nil
                spawner.start(task: updated, project: project,
                              apiKey: APIKeyResolver.resolve(),
                              store: store, server: server, approvalQueue: approvalQueue)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

