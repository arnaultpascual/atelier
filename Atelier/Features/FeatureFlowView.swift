// SPDX-License-Identifier: MIT
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
        case .tasks, .building, .finish: placeholder(viewedStage)
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
        return !(room.briefText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ③–⑤ — placeholders until their phase wires the existing component.
    private func placeholder(_ s: Feature.Stage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            stageHeading(s)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer.fill").foregroundStyle(Color.atelierAccent)
                    Text("Wired in an upcoming phase").font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
                }
                Text(placeholderDetail(s))
                    .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("For now, use “Classic kanban” from the feature list to build with the existing flow.")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.atelierSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
            advanceBar(primaryTitle: "Continue")
        }
    }

    private func placeholderDetail(_ s: Feature.Stage) -> String {
        switch s {
        case .brief: return "This stage will host brief co-authoring + multi-pass refinement (the existing Prepare-Prompt flow), scoped to this feature, until the brief stabilises."
        case .tasks: return "This stage will host decomposition into a task list you can edit and iterate on per task (the existing Fill-Kanban flow), feeding this feature's backlog."
        case .building: return "This stage will host this feature's kanban + the autopilot run (dev → test gate → review → merge), scoped to the feature's tasks."
        case .finish: return "This stage will host the automatic final synthesis: re-test, coverage, conformity to the brief, and the FEATURE-<slug>.md deliverable at the project root."
        case .prerequisites: return s.summary
        }
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
        viewedStage == .brief ? "Write or refine the brief first." : ""
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
        var f = store.featureByID(feature.id) ?? feature
        f.briefRoomId = room.id
        try? await store.updateFeature(f)
    }

    private func advance(to next: Feature.Stage) {
        advancing = true
        Task {
            var f = store.featureByID(feature.id) ?? feature
            if next.order > f.stage.order { f.stage = next }
            try? await store.updateFeature(f)
            await MainActor.run { advancing = false; viewedStage = next }
        }
    }

    private func completeFeature() {
        advancing = true
        Task {
            var f = store.featureByID(feature.id) ?? feature
            f.completedAt = Date()
            try? await store.updateFeature(f)
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
