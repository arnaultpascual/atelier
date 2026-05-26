// SPDX-License-Identifier: MIT
import SwiftUI

/// Full planning surface for an autopilot batch: lay the To-Do backlog out as its execution
/// rounds (lanes), drag a task between lanes to set what it waits on, then launch autopilot on
/// N batches. Dragging a task into round N rewrites its `dependsOn` to the previous round's
/// tasks (round 1 = no deps); the rounds re-derive live via `ExecutionPlanner`, so the lanes are
/// both the view *and* the editor. Cycle-safe: a task never gains a dependency on something that
/// (transitively) depends on it.
struct PlanBatchView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var featureRunner: FeatureBuildRunner
    let project: Project
    let onClose: () -> Void

    @State private var batches: Int = 1
    @State private var budgetText: String = ""
    @State private var dropTargetRound: Int?
    @State private var confirmStart = false

    private var allTasks: [AtelierTask] { store.tasks(in: project.id) }
    private var todo: [AtelierTask] { allTasks.filter { $0.status == .toDo } }
    private var waves: [(round: Int, tasks: [AtelierTask])] {
        ExecutionPlanner.waves(tasks: todo, allTasks: allTasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            AtelierDivider()
            if waves.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(waves, id: \.round) { wave in
                            lane(round: wave.round, tasks: wave.tasks)
                        }
                        Text("Drag a task up or down between rounds to change which tasks it waits on. A task in round 1 runs first; dropping it into a later round makes it depend on the round above.")
                            .font(AtelierFont.caption)
                            .foregroundStyle(Color.atelierInkSecondary)
                            .padding(.top, 4)
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 920, minHeight: 520, idealHeight: 700)
        .background(Color.atelierBackground)
        .onAppear { batches = max(1, waves.count) }
        .confirmationDialog("Start unsupervised autopilot?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start \(batches) batch\(batches == 1 ? "" : "es")", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Autopilot builds, reviews, fixes and auto-merges \(batches) round\(batches == 1 ? "" : "s") onto a throwaway atelier/autopilot-* branch — unattended, with tool approvals auto-accepted except your explicit deny rules. Your branch is untouched and nothing is pushed.")
        }
    }

    // MARK: Header (config + launch)

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan the batch")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("\(waves.count) round\(waves.count == 1 ? "" : "s") · \(todo.count) To-Do task\(todo.count == 1 ? "" : "s") · \(project.name)")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                SectionLabel("STOP IF SPEND > $")
                TextField("opt.", text: $budgetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
            }
            Stepper(value: $batches, in: 1...max(1, waves.count)) {
                Text("Build \(batches) batch\(batches == 1 ? "" : "es")")
                    .font(AtelierFont.caption)
            }
            .fixedSize()
            startButton
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var startButton: some View {
        let running = featureRunner.isActive(projectId: project.id)
        let ready = canStart && !running
        Button(action: { confirmStart = true }) {
            HStack(spacing: 5) {
                Image(systemName: "infinity").font(.system(size: 10))
                Text(running ? "Autopilot running" : "Start")
                    .font(.system(.callout).weight(.semibold))
            }
            .foregroundStyle(ready ? .white : Color.atelierInkSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(ready ? Color.atelierAccent : Color.atelierSurface,
                        in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control)
                .stroke(ready ? Color.clear : Color.atelierDivider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help("Build \(batches) round\(batches == 1 ? "" : "s") autonomously — review, fix, and merge into a throwaway atelier/autopilot-* branch. Nothing is pushed.")
    }

    private var canStart: Bool {
        server.helperReady && !ExecutionPlanner.runnableNow(tasks: todo, allTasks: allTasks).isEmpty
    }

    private func start() {
        let cap = Double(budgetText.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
        featureRunner.start(project: project, batches: batches, budgetCapUsd: cap,
                            store: store, spawner: spawner, server: server, approvalQueue: approvalQueue)
        onClose()
    }

    // MARK: Lanes

    private func lane(round: Int, tasks: [AtelierTask]) -> some View {
        let targeted = dropTargetRound == round
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("ROUND \(round)")
                    .font(AtelierFont.eyebrow.weight(.semibold))
                    .foregroundStyle(round == 1 ? Color.atelierAccent : Color.atelierInkSecondary)
                Text(round == 1 ? "runs first · \(tasks.count) in parallel" : "waits on round \(round - 1)")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(tasks) { chip($0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(targeted ? Color.atelierAccent.opacity(0.08) : Color.atelierSurface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card)
            .stroke(targeted ? Color.atelierAccent : Color.atelierDivider.opacity(0.5),
                    lineWidth: targeted ? 1.5 : 1))
        .dropDestination(for: String.self) { ids, _ in
            applyDrop(ids: ids, toRound: round)
        } isTargeted: { inside in
            if inside { dropTargetRound = round }
            else if dropTargetRound == round { dropTargetRound = nil }
        }
    }

    private func chip(_ t: AtelierTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t.title)
                .font(AtelierFont.caption.weight(.medium))
                .foregroundStyle(Color.atelierInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(t.id)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                if let p = t.priority { PriorityPill(priority: p) }
                if !t.dependsOn.isEmpty { DependencyChip(count: t.dependsOn.count) }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atelierCard(border: Color.atelierDivider)
        .draggable(t.id)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 76, height: 76)
                Image(systemName: "infinity")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.atelierAccent)
            }
            Text("Nothing to plan")
                .font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
            Text("Add some To-Do tasks (or use Fill kanban), then come back to organize them into batches.")
                .multilineTextAlignment(.center)
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drop → dependency edit

    /// Dropping a task into round N makes it wait on round N-1's tasks (round 1 = no deps).
    /// Excludes the task itself and anything that (transitively) depends on it, so the move can
    /// never introduce a cycle.
    private func applyDrop(ids: [String], toRound round: Int) -> Bool {
        let previous: [String] = round <= 1
            ? []
            : (waves.first(where: { $0.round == round - 1 })?.tasks.map(\.id) ?? [])
        var changed = false
        for id in ids {
            guard let task = store.taskByID(id), task.status == .toDo else { continue }
            let unsafe = dependentsClosure(of: id)
            let newDeps = previous.filter { $0 != id && !unsafe.contains($0) }.sorted()
            guard Set(newDeps) != Set(task.dependsOn) else { continue }
            var updated = task
            updated.dependsOn = newDeps
            Task { try? await store.updateTask(updated) }
            changed = true
        }
        dropTargetRound = nil
        return changed
    }

    /// Every task that (transitively) depends on `id` — these can't become `id`'s dependencies.
    private func dependentsClosure(of id: String) -> Set<String> {
        let all = allTasks
        var result: Set<String> = []
        var frontier = [id]
        while let current = frontier.popLast() {
            for t in all where t.dependsOn.contains(current) && !result.contains(t.id) {
                result.insert(t.id)
                frontier.append(t.id)
            }
        }
        return result
    }
}
