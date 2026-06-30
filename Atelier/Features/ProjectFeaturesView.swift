// SPDX-License-Identifier: MIT
import SwiftUI

/// The feature-first project view: a project is a list of FEATURES, each walked through the guided
/// flow (prerequisites → brief → tasks → build → finish). Selecting or creating a feature opens
/// `FeatureFlowView`. A "Classic kanban" escape hatch still exposes the project-level board so
/// existing task work isn't lost while the guided flow is being built out across phases.
struct ProjectFeaturesView: View {
    let store: AppStore
    let spawner: TaskSpawner
    let server: ApprovalServer
    let approvalQueue: ApprovalQueue
    let featureRunner: FeatureBuildRunner
    let chatSpawner: ChatSpawner
    let project: Project
    @Binding var selectedTaskID: String?

    @State private var selectedFeatureId: String?
    @State private var showClassicKanban = false
    @State private var newFeatureName = ""
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private var profile: ProjectProfile { ProjectProfile.find(id: project.profileId) ?? .generic }
    private var features: [Feature] { store.features(in: project.id) }

    var body: some View {
        Group {
            if let fid = selectedFeatureId, let feature = store.featureByID(fid) {
                FeatureFlowView(store: store, spawner: spawner, server: server,
                                approvalQueue: approvalQueue, featureRunner: featureRunner,
                                chatSpawner: chatSpawner, project: project, feature: feature,
                                selectedTaskID: $selectedTaskID,
                                onBack: { selectedFeatureId = nil })
            } else if showClassicKanban {
                classicKanban
            } else {
                featuresList
            }
        }
        .background(Color.atelierBackground)
    }

    // MARK: Escape hatch — the existing project kanban, with a way back to features.

    private var classicKanban: some View {
        BacklogPane(store: store, spawner: spawner, server: server, approvalQueue: approvalQueue,
                    featureRunner: featureRunner, chatSpawner: chatSpawner,
                    selectedProjectID: project.id, selectedTaskID: $selectedTaskID)
            .overlay(alignment: .topTrailing) {
                Button { showClassicKanban = false } label: {
                    Label("Features", systemImage: "square.grid.2x2")
                        .font(AtelierFont.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.atelierSurface, in: Capsule())
                        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 24).padding(.trailing, 16)
                .help("Back to the feature list.")
            }
    }

    // MARK: Features list

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 16)   // reserve space for the macOS traffic lights
            header
            ScrollView {
                if features.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 14)], spacing: 14) {
                        ForEach(features) { f in
                            FeatureCard(feature: f) { selectedFeatureId = f.id }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: profile.iconSystemName).foregroundStyle(Color.atelierAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(AtelierFont.title).foregroundStyle(Color.atelierInk)
                    Text("\(features.count) feature\(features.count == 1 ? "" : "s") · \(profile.name)")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                }
                Spacer()
                Button { showClassicKanban = true } label: {
                    Label("Classic kanban", systemImage: "rectangle.split.3x1")
                        .font(AtelierFont.caption.weight(.medium))
                }
                .help("Open the project-level kanban board (all tasks, not feature-scoped).")
            }
            newFeatureRow
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var newFeatureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Color.atelierAccent)
            TextField("New feature — name it (e.g. “Export users to CSV”)", text: $newFeatureName)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit(createFeature)
            if creating { ProgressView().controlSize(.small) }
            Button("Create", action: createFeature)
                .buttonStyle(.borderedProminent)
                .disabled(newFeatureName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32)).foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
            Text("No features yet").font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
            Text("A feature walks you through the whole build, step by step: prerequisites → brief → tasks → autopilot → deliverables. Name your first one above to begin.")
                .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity).padding(.top, 60).padding(20)
    }

    private func createFeature() {
        let name = newFeatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !creating else { return }
        creating = true
        Task {
            let f = try? await store.createFeature(in: project, name: name)
            await MainActor.run {
                creating = false
                if let f { newFeatureName = ""; selectedFeatureId = f.id }
            }
        }
    }
}

// MARK: - Feature card

private struct FeatureCard: View {
    let feature: Feature
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: feature.isCompleted ? "checkmark.seal.fill" : feature.stage.iconSystemName)
                        .foregroundStyle(feature.isCompleted ? Palette.success : Color.atelierAccent)
                    Text(feature.name).font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                stageProgress
                HStack(spacing: 6) {
                    Text(feature.isCompleted ? "Done" : "Stage \(feature.stage.order + 1)/5 · \(feature.stage.label)")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(feature.isCompleted ? Palette.success : Color.atelierInkSecondary)
                    Spacer()
                    Text(feature.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.atelierSurface.opacity(hover ? 0.85 : 0.5), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card)
                .stroke(feature.isCompleted ? Palette.success.opacity(0.4) : Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var stageProgress: some View {
        HStack(spacing: 4) {
            ForEach(Feature.Stage.allCases, id: \.self) { s in
                Capsule().fill(color(for: s)).frame(height: 4)
            }
        }
    }

    private func color(for s: Feature.Stage) -> Color {
        if feature.isCompleted { return Palette.success.opacity(0.7) }
        if s.order < feature.stage.order { return Color.atelierAccent }
        if s == feature.stage { return Color.atelierAccent.opacity(0.55) }
        return Color.atelierDivider.opacity(0.6)
    }
}
