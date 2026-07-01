// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Guided, stage-by-stage flow for one feature. The stepper header shows the five stages; the body
/// shows the *viewed* stage (which can be any stage already reached). Phase 1 wires stage ①
/// (prerequisites) and shows ②–⑤ as placeholders that later phases fill with the existing
/// brief / decompose / kanban+autopilot / synthesis components.
struct FeatureFlowView: View {
    let store: AppStore
    let spawner: TaskSpawner
    let server: ApprovalServer
    let approvalQueue: ApprovalQueue
    let featureRunner: FeatureBuildRunner
    let chatSpawner: ChatSpawner
    let project: Project
    let feature: Feature
    @Binding var selectedTaskID: String?
    let onBack: () -> Void

    @State private var viewedStage: Feature.Stage
    @State private var toolchain: ToolchainChecker.Report?
    @State private var advancing = false
    // ③ Tasks
    @State private var decomposing = false
    @State private var decomposeError: String?
    @State private var inspectRepo = true
    @State private var quickAddTitle = ""
    // ⑤ Finish
    @State private var deliverableMarkdown: String?
    @State private var finalizing = false
    @State private var mergeError: String?

    init(store: AppStore, spawner: TaskSpawner, server: ApprovalServer, approvalQueue: ApprovalQueue,
         featureRunner: FeatureBuildRunner, chatSpawner: ChatSpawner, project: Project, feature: Feature,
         selectedTaskID: Binding<String?>, onBack: @escaping () -> Void) {
        self.store = store
        self.spawner = spawner
        self.server = server
        self.approvalQueue = approvalQueue
        self.featureRunner = featureRunner
        self.chatSpawner = chatSpawner
        self.project = project
        self.feature = feature
        self._selectedTaskID = selectedTaskID
        self.onBack = onBack
        self._viewedStage = State(initialValue: feature.stage)
    }

    /// Live feature row (the passed `feature` is the snapshot at open time; stage advances persist).
    private var live: Feature { store.featureByID(feature.id) ?? feature }
    private var profile: ProjectProfile { ProjectProfile.find(id: project.profileId) ?? .generic }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 16)   // traffic-light reserve
            headerBar
            Divider().background(Color.atelierDivider).opacity(0.6)
            ScrollView {
                stageContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.atelierBackground)
        .task(id: viewedStage) {
            await loadToolchainIfNeeded()
            await ensureBriefRoomIfNeeded()
        }
        .task(id: deliverableLoadKey) { loadDeliverable() }
    }

    /// Reload the deliverable when we enter Finish or when the synthesis writes/updates its path.
    private var deliverableLoadKey: String { "\(viewedStage.rawValue)|\(live.deliverablePath ?? "")" }
    private func loadDeliverable() {
        guard viewedStage == .finish, let path = live.deliverablePath else { deliverableMarkdown = nil; return }
        deliverableMarkdown = try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: Header + stepper

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label("Features", systemImage: "chevron.left").font(AtelierFont.caption.weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(Color.atelierAccent)
                Text(live.name).font(AtelierFont.title).foregroundStyle(Color.atelierInk).lineLimit(1)
                Spacer()
                Text(project.name).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            }
            stepper
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var stepper: some View {
        HStack(spacing: 4) {
            ForEach(Array(Feature.Stage.allCases.enumerated()), id: \.element) { idx, s in
                stageChip(s, index: idx)
                if idx < Feature.Stage.allCases.count - 1 {
                    Rectangle().fill(connectorColor(after: s)).frame(height: 2).frame(maxWidth: 28)
                }
            }
        }
    }

    private func stageChip(_ s: Feature.Stage, index: Int) -> some View {
        let reached = s.order <= live.stage.order || live.isCompleted
        let completed = s.order < live.stage.order || live.isCompleted
        let isViewed = s == viewedStage
        return Button {
            if reached { viewedStage = s }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(completed ? Color.atelierAccent
                              : (s == live.stage ? Color.atelierAccent.opacity(0.18) : Color.atelierSurface))
                        .frame(width: 22, height: 22)
                    if completed {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(index + 1)").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(s == live.stage ? Color.atelierAccent : Color.atelierInkSecondary)
                    }
                }
                Text(s.label)
                    .font(AtelierFont.caption.weight(isViewed ? .semibold : .regular))
                    .foregroundStyle(reached ? Color.atelierInk : Color.atelierInkSecondary.opacity(0.5))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isViewed ? Color.atelierAccentSoft.opacity(0.4) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!reached)
        .help(s.summary)
    }

    private func connectorColor(after s: Feature.Stage) -> Color {
        (s.order < live.stage.order || live.isCompleted) ? Color.atelierAccent : Color.atelierDivider.opacity(0.6)
    }

    // MARK: Stage content

    @ViewBuilder
    private var stageContent: some View {
        switch viewedStage {
        case .prerequisites: prerequisitesStage
        case .brief: briefStage
        case .tasks: tasksStage
        case .building: buildStage
        case .finish: finishStage
        }
    }

    private func stageHeading(_ s: Feature.Stage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: s.iconSystemName).foregroundStyle(Color.atelierAccent)
                Text(s.label).font(AtelierFont.title).foregroundStyle(Color.atelierInk)
            }
            Text(s.summary).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
        }
    }

    // ① Prerequisites — wired.
    private var prerequisitesStage: some View {
        let ready = (toolchain?.ready ?? false) || profile.build.requiredTools.isEmpty
        return VStack(alignment: .leading, spacing: 16) {
            stageHeading(.prerequisites)
            if profile.build.requiredTools.isEmpty {
                CalloutBanner(.info, "The \(profile.name) mode needs no special toolchain — you're good to go.")
            } else {
                ToolchainReadinessView(profile: profile, report: toolchain)
                if toolchain == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking the toolchain…").font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                    }
                } else if let r = toolchain, !r.ready {
                    CalloutBanner(.warning, "\(r.missingSummary) missing — install it (hints above) so the build can run, or continue anyway and fix it later. This never blocks you.")
                } else {
                    CalloutBanner(.info, "Toolchain ready — the build can run this mode's tests.")
                }
            }
            advanceBar(primaryTitle: ready ? "Continue to Brief" : "Continue anyway")
        }
    }

    // ② Brief — wired: the multi-pass refinement flow, scoped to this feature's brief room.
    private var briefStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            stageHeading(.brief)
            if let roomId = live.briefRoomId, store.chatRoom(id: roomId) != nil {
                PreparePromptView(store: store, chatSpawner: chatSpawner, project: project, pinnedBriefId: roomId)
                    .frame(height: 600)
                    .background(Color.atelierSurface.opacity(0.25), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Setting up the brief workspace…").font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            advanceBar(primaryTitle: "Continue to Tasks", canAdvance: briefReady)
        }
    }

    private var briefReady: Bool {
        guard let roomId = live.briefRoomId, let room = store.chatRoom(id: roomId) else { return false }
        let content = (try? String(contentsOf: room.briefFileURL, encoding: .utf8)) ?? ""
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ③ Tasks — wired: decompose the feature's brief into its own tasks, editable inline.
    private var tasksStage: some View {
        let featureTasks = store.tasks(inFeature: feature.id)
        return VStack(alignment: .leading, spacing: 16) {
            stageHeading(.tasks)
            if featureTasks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Decompose the brief into a task list. You can then edit each task, add or remove some, before building.")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $inspectRepo) {
                        Text("Inspect the repo so tasks reference real files (slower, pricier)").font(AtelierFont.caption)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    Button(action: decomposeIntoFeature) {
                        HStack(spacing: 6) {
                            if decomposing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "wand.and.stars") }
                            Text(decomposing ? "Decomposing…" : "Decompose brief into tasks").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(decomposing || !briefReady)
                    if !briefReady {
                        Text("Write the brief first (stage ②).").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    }
                    if let err = decomposeError { CalloutBanner(.danger, err) }
                }
            } else {
                HStack {
                    Text("\(featureTasks.count) task\(featureTasks.count == 1 ? "" : "s")")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                    Spacer()
                    Button(action: decomposeIntoFeature) {
                        HStack(spacing: 4) {
                            if decomposing { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                            Text(decomposing ? "Decomposing…" : "Re-decompose").font(AtelierFont.caption)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.atelierAccent).disabled(decomposing)
                    .help("Generate more tasks from the brief (adds to the list).")
                }
                VStack(spacing: 8) { ForEach(featureTasks) { featureTaskRow($0) } }
                quickAddRow
                if let err = decomposeError { CalloutBanner(.danger, err) }
            }
            advanceBar(primaryTitle: "Continue to Build", canAdvance: !featureTasks.isEmpty)
        }
    }

    private func featureTaskRow(_ t: AtelierTask) -> some View {
        HStack(spacing: 10) {
            Button { selectedTaskID = t.id } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(AtelierFont.caption.weight(.medium)).foregroundStyle(Color.atelierInk)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let p = t.priority {
                            Text(p.displayName.uppercased()).font(AtelierFont.eyebrow).foregroundStyle(Color.atelierAccent)
                        }
                        if !t.labels.isEmpty {
                            Text(t.labels.joined(separator: ", ")).font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                        }
                        if !t.dependsOn.isEmpty {
                            Label("\(t.dependsOn.count)", systemImage: "arrow.turn.down.right")
                                .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                        }
                        Text(t.status.displayName).font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open to edit / iterate on this task.")
            Button { deleteTask(t) } label: { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
                .help("Delete this task.")
        }
        .padding(10)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var quickAddRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(Color.atelierAccent)
            TextField("Add a task by hand…", text: $quickAddTitle)
                .textFieldStyle(.plain).onSubmit(quickAddTask)
            Button("Add", action: quickAddTask)
                .controlSize(.small)
                .disabled(quickAddTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.atelierSurface.opacity(0.3), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    // ④ Build — wired: feature-scoped kanban + autopilot (runs only this feature's tasks).
    private var buildStage: some View {
        let featureTasks = store.tasks(inFeature: feature.id)
        let run = featureRunner.run(forFeature: feature.id)
        return VStack(alignment: .leading, spacing: 16) {
            stageHeading(.building)
            if run == nil { buildVerifyOptions }   // configure the optional app build before starting
            autopilotBar(run: run, featureTasks: featureTasks)
            featureKanban(featureTasks: featureTasks, run: run)
            // Also open the gate when a deliverable exists — the in-memory run is gone after a relaunch.
            advanceBar(primaryTitle: "Continue to Finish", canAdvance: run?.status == .finished || live.deliverablePath != nil)
        }
    }

    /// Opt-in app-build verification (the gate stays unit tests): before each merge and/or a final
    /// build + fix pass once everything is merged. Persisted on the project; picked up at launch.
    private var buildVerifyOptions: some View {
        let cmd = (store.projectByID(project.id) ?? project).resolvedVerifyBuildCommand(profile: profile)
        return VStack(alignment: .leading, spacing: 6) {
            Text("APP BUILD — optional (unit tests stay the gate)")
                .font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierInkSecondary)
            if let cmd {
                Toggle(isOn: Binding(get: { store.projectByID(project.id)?.buildVerifyBeforeMerge ?? false },
                                     set: { setBuildVerify(perMerge: $0) })) {
                    Text("Verify the app build before EACH task merge (+ fix)").font(AtelierFont.caption)
                }.toggleStyle(.switch).controlSize(.small)
                Toggle(isOn: Binding(get: { store.projectByID(project.id)?.buildVerifyFinal ?? false },
                                     set: { setBuildVerify(final: $0) })) {
                    Text("Final app build + fix pass once all tasks are merged").font(AtelierFont.caption)
                }.toggleStyle(.switch).controlSize(.small)
                Text("Command: \(cmd)").font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary).textSelection(.enabled)
            } else {
                Text("This mode has no build command — app build unavailable; unit tests still gate.")
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface.opacity(0.35), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private func setBuildVerify(perMerge: Bool? = nil, final: Bool? = nil) {
        Task {
            try? await store.updateProject(id: project.id) { p in
                if let perMerge { p.buildVerifyBeforeMerge = perMerge }
                if let final { p.buildVerifyFinal = final }
            }
        }
    }

    @ViewBuilder
    private func autopilotBar(run: AutopilotRun?, featureTasks: [AtelierTask]) -> some View {
        let runnable = ExecutionPlanner.runnableNow(tasks: featureTasks.filter { $0.status == .toDo }, allTasks: featureTasks)
        HStack(spacing: 10) {
            if let run {
                switch run.status {
                case .running, .stopping:
                    ProgressView().controlSize(.small)
                    Text(autopilotStatusText(run)).font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                    Spacer()
                    Button("Stop") { featureRunner.stop(featureId: feature.id, force: false) }.controlSize(.small)
                case .paused(let msg):
                    Image(systemName: "pause.circle.fill").foregroundStyle(Palette.warning)
                    Text(msg).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary).lineLimit(2)
                    Spacer()
                    Button("Resume") { featureRunner.resume(featureId: feature.id) }.controlSize(.small)
                case .finished:
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text("Autopilot finished — \(mergedCount(run))/\(run.taskPhases.count) merged · $\(String(format: "%.2f", run.totalCostUsd)).")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                    Spacer()
                    Button("Run again") { featureRunner.clearRun(featureId: feature.id); startFeatureAutopilot(featureTasks) }.controlSize(.small)
                case .failed(let msg):
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.error)
                    Text(msg).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary).lineLimit(2)
                    Spacer()
                    Button("Retry") { featureRunner.clearRun(featureId: feature.id); startFeatureAutopilot(featureTasks) }.controlSize(.small)
                }
            } else {
                let projectBusy = featureRunner.isProjectBusy(project.id)
                Image(systemName: "infinity").foregroundStyle(Color.atelierAccent)
                Text(projectBusy ? "Another build is running for this project — one at a time (they share the repo)."
                     : (runnable.isEmpty ? "No runnable task — add tasks in the Tasks stage."
                                         : "\(featureTasks.count) task\(featureTasks.count == 1 ? "" : "s") ready to build."))
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                Button(action: { startFeatureAutopilot(featureTasks) }) {
                    Label("Start autopilot", systemImage: "play.fill").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!server.helperReady || runnable.isEmpty || projectBusy)
                .help(!server.helperReady ? "The approval helper isn't ready yet."
                      : projectBusy ? "Finish or stop the other build for this project first."
                                    : "Build this feature's tasks: dev → test gate → review → merge → re-test.")
            }
        }
        .padding(12)
        .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func featureKanban(featureTasks: [AtelierTask], run: AutopilotRun?) -> some View {
        let byStatus = Dictionary(grouping: featureTasks, by: \.status)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AtelierTask.Status.kanbanOrder, id: \.self) { status in
                    let colTasks = byStatus[status] ?? []
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(status.displayName).font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierInkSecondary)
                            Text("\(colTasks.count)").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                        }
                        if colTasks.isEmpty {
                            Text("—").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.4))
                        } else {
                            ForEach(colTasks) { buildTaskCard($0, phase: run?.taskPhases[$0.id]) }
                        }
                    }
                    .frame(width: 178, alignment: .top)
                    .padding(10)
                    .background(Color.atelierSurface.opacity(0.3), in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func buildTaskCard(_ t: AtelierTask, phase: TaskPhase?) -> some View {
        Button { selectedTaskID = t.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title).font(AtelierFont.eyebrow.weight(.medium)).foregroundStyle(Color.atelierInk)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let phase {
                    HStack(spacing: 3) {
                        if phase.isActive { ProgressView().controlSize(.mini).scaleEffect(0.6) }
                        Text(phase.label).font(.system(size: 9)).foregroundStyle(phaseColor(phase)).lineLimit(1)
                    }
                }
                // Live progress reported by the worker over the MCP capability bridge.
                if let prog = store.taskProgress[t.id] {
                    HStack(spacing: 4) {
                        Text("\(prog.pct)%")
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.atelierAccent)
                        if let note = prog.note, !note.isEmpty {
                            Text(note).font(.system(size: 9))
                                .foregroundStyle(Color.atelierInkSecondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .help("Open to inspect this task.")
    }

    private func mergedCount(_ run: AutopilotRun) -> Int {
        run.taskPhases.values.filter { $0 == .done }.count
    }

    private func autopilotStatusText(_ run: AutopilotRun) -> String {
        "Building… round \(run.currentRound), \(mergedCount(run))/\(run.taskPhases.count) merged · $\(String(format: "%.2f", run.totalCostUsd))"
    }

    private func phaseColor(_ p: TaskPhase) -> Color {
        switch p {
        case .done: return Palette.success
        case .blocked: return Palette.error
        case .queued: return Color.atelierInkSecondary
        default: return Color.atelierAccent
        }
    }

    private func startFeatureAutopilot(_ featureTasks: [AtelierTask]) {
        // Pick up the latest project (build-verify toggles the user may have just flipped).
        let freshProject = store.projectByID(project.id) ?? project
        let toDo = featureTasks.filter { $0.status == .toDo }
        let batches = max(1, ExecutionPlanner.waves(tasks: toDo, allTasks: featureTasks).count)
        featureRunner.start(project: freshProject, feature: live, batches: batches, budgetCapUsd: nil,
                            store: store, spawner: spawner, server: server, approvalQueue: approvalQueue)
    }

    // ⑤ Finish — wired: surface the auto-generated deliverable + finalize (merge + complete).
    private var finishStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            stageHeading(.finish)
            if let md = deliverableMarkdown {
                deliverablePanel(md)
            } else if live.deliverablePath != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading the deliverable…").font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                }
            } else {
                CalloutBanner(.info, "The deliverable (FEATURE-<slug>.md at the project root) is generated automatically when the autopilot finishes. Complete the Build stage first.")
            }
            finalizePanel
        }
    }

    private func deliverablePanel(_ md: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DELIVERABLE").font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierInk)
                Spacer()
                if let path = live.deliverablePath {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.controlSize(.small)
                    Button("Copy") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(md, forType: .string)
                    }.controlSize(.small)
                }
            }
            ScrollView {
                MarkdownView(source: md).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(height: 380)
            .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
            if let path = live.deliverablePath {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var finalizePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if live.isCompleted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text("Feature completed\(live.completedAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "").")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInk)
                }
            } else {
                if let branch = live.integrationBranch, !branch.isEmpty {
                    Text("Integration branch: \(branch)").font(AtelierFont.captionMono).foregroundStyle(Color.atelierInkSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 10) {
                        Button(action: mergeAndFinish) {
                            HStack(spacing: 6) {
                                if finalizing { ProgressView().controlSize(.small) }
                                Text("Merge & finish").fontWeight(.semibold)
                                Image(systemName: "arrow.triangle.merge")
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(finalizing)
                        Button("Mark done without merging") { markDoneOnly() }.controlSize(.small).disabled(finalizing)
                    }
                } else {
                    Button("Mark feature done") { markDoneOnly() }.buttonStyle(.borderedProminent).disabled(finalizing)
                }
                if let err = mergeError { CalloutBanner(.danger, err) }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Advance / navigate

    @ViewBuilder
    private func advanceBar(primaryTitle: String, canAdvance: Bool = true) -> some View {
        HStack(spacing: 10) {
            if viewedStage.order < live.stage.order {
                Button("Go to current stage (\(live.stage.label))") { viewedStage = live.stage }
                    .buttonStyle(.bordered)
                Spacer()
            } else {
                if !canAdvance, !advanceHint.isEmpty {
                    Label(advanceHint, systemImage: "info.circle")
                        .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer()
                if let next = nextStage(after: viewedStage) {
                    Button(action: { advance(to: next) }) {
                        HStack(spacing: 6) {
                            if advancing { ProgressView().controlSize(.small) }
                            Text(primaryTitle).fontWeight(.semibold)
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(advancing || !canAdvance)
                } else {
                    Button(action: completeFeature) {
                        HStack(spacing: 6) {
                            if advancing { ProgressView().controlSize(.small) }
                            Text(live.isCompleted ? "Feature done" : "Mark feature done").fontWeight(.semibold)
                            Image(systemName: "checkmark.seal")
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(advancing || live.isCompleted)
                }
            }
        }
        .padding(.top, 8)
    }

    private var advanceHint: String {
        switch viewedStage {
        case .brief: return "Write or refine the brief first."
        case .building: return "Run the autopilot to completion first."
        default: return ""
        }
    }

    private func nextStage(after s: Feature.Stage) -> Feature.Stage? {
        let all = Feature.Stage.allCases
        guard let i = all.firstIndex(of: s), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    /// Lazily create + link this feature's brief room when the user reaches the Brief stage.
    private func ensureBriefRoomIfNeeded() async {
        guard viewedStage == .brief, live.briefRoomId == nil else { return }
        guard let room = try? await store.createBriefRoom(projectId: project.id) else { return }
        try? await store.updateFeature(id: feature.id) { $0.briefRoomId = room.id }
    }

    // MARK: ③ Tasks actions

    /// Decompose the feature's (refined) brief into tasks, each stamped with this feature's id.
    /// Additive — a re-decompose appends more tasks to the list.
    private func decomposeIntoFeature() {
        guard let roomId = live.briefRoomId, let room = store.chatRoom(id: roomId) else { return }
        let brief = ((try? String(contentsOf: room.briefFileURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }
        decomposing = true
        decomposeError = nil
        let profileSnapshot = profile
        let projectSnapshot = project
        // Dedup within THIS feature — not the whole project — so it matches the feature-scoped write.
        let titles = store.tasks(inFeature: feature.id).map(\.title)
        let repoPath = inspectRepo ? project.path : nil
        let featureId = feature.id
        Task {
            do {
                let drafts = try await AIAssistant.decomposeBrief(
                    brief, project: projectSnapshot, profile: profileSnapshot,
                    existingTitles: titles, repoPath: repoPath)
                guard !drafts.isEmpty else {
                    await MainActor.run { decomposing = false; decomposeError = "The decomposer returned no tasks — refine the brief and try again." }
                    return
                }
                _ = try await store.createTasks(fromDrafts: drafts, in: projectSnapshot, featureId: featureId)
                await MainActor.run { decomposing = false }
            } catch {
                await MainActor.run { decomposing = false; decomposeError = "Decomposition failed: \(error.localizedDescription)" }
            }
        }
    }

    private func quickAddTask() {
        let title = quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let featureId = feature.id
        let projectSnapshot = project
        Task {
            _ = try? await store.createTask(in: projectSnapshot, title: title, featureId: featureId)
            await MainActor.run { quickAddTitle = "" }
        }
    }

    private func deleteTask(_ t: AtelierTask) {
        Task { try? await store.deleteTask(t) }
    }

    // MARK: ⑤ Finish actions

    private func markDoneOnly() {
        finalizing = true
        Task {
            try? await store.updateFeature(id: feature.id) { $0.completedAt = Date() }
            await MainActor.run { finalizing = false }
        }
    }

    /// Merge the feature's integration branch into the currently checked-out branch (guarding
    /// protected branches, aborting cleanly on conflict), then mark the feature completed.
    private func mergeAndFinish() {
        guard let branch = live.integrationBranch, !branch.isEmpty else { return }
        finalizing = true; mergeError = nil
        let projectPath = project.path
        Task {
            do {
                let base = try await GitService.currentBranch(projectPath: projectPath)
                if GitService.protectedBranches.contains(base.lowercased()) {
                    await MainActor.run {
                        finalizing = false
                        mergeError = "You're on protected branch “\(base)”. Check out your integration/feature branch, or merge \(branch) by hand."
                    }
                    return
                }
                let result = try await GitService.merge(into: base, branch: branch, projectPath: projectPath)
                switch result {
                case .clean, .upToDate:
                    try? await store.updateFeature(id: feature.id) { $0.completedAt = Date() }
                    await MainActor.run { finalizing = false }
                case .conflict(let files):
                    try? await GitService.abortMerge(projectPath: projectPath)
                    await MainActor.run {
                        finalizing = false
                        mergeError = "Merge conflicts in \(files.count) file(s). Aborted — merge \(branch) into \(base) by hand."
                    }
                }
            } catch {
                await MainActor.run { finalizing = false; mergeError = error.localizedDescription }
            }
        }
    }

    private func advance(to next: Feature.Stage) {
        advancing = true
        Task {
            try? await store.updateFeature(id: feature.id) { if next.order > $0.stage.order { $0.stage = next } }
            await MainActor.run { advancing = false; viewedStage = next }
        }
    }

    private func completeFeature() {
        advancing = true
        Task {
            try? await store.updateFeature(id: feature.id) { $0.completedAt = Date() }
            await MainActor.run { advancing = false }
        }
    }

    private func loadToolchainIfNeeded() async {
        guard viewedStage == .prerequisites, !profile.build.requiredTools.isEmpty else {
            toolchain = nil; return
        }
        toolchain = await ToolchainChecker.check(profile: profile, projectPath: project.path)
    }
}
