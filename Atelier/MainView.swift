// SPDX-License-Identifier: MIT
import SwiftUI

/// Two-column shell (Workspaces → Backlog kanban) with an inspector panel that
/// slides in from the right when a task is selected. When no task is selected, the
/// kanban gets the full content width.
struct MainView: View {
    @Bindable var store: AppStore
    @Bindable var server: ApprovalServer
    @Bindable var spawner: TaskSpawner
    @Bindable var approvalQueue: ApprovalQueue
    @Bindable var chatSpawner: ChatSpawner
    @Bindable var featureRunner: FeatureBuildRunner


    enum CenterTarget: Hashable {
        case chat
        case swarm
        case approvals
        case usage
        case project(String)
    }

    @State private var centerTarget: CenterTarget?
    @State private var selectedTaskID: String?
    @State private var presentingAddWorkspace = false
    @State private var addProjectTarget: Workspace?
    @State private var showSetup = false
    @AppStorage("atelier.onboarding.completed") private var onboardingCompleted = false
    @AppStorage("atelier.onboarding.reopen") private var onboardingReopen = false

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                store: store,
                server: server,
                spawner: spawner,
                approvalQueue: approvalQueue,
                centerTarget: $centerTarget,
                onAddWorkspace: { presentingAddWorkspace = true },
                onAddProject: { ws in addProjectTarget = ws }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            centerView
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color.atelierBackground)
        .onChange(of: centerTarget) { _, _ in
            // Clear task selection when navigating to a different project or to swarm.
            selectedTaskID = nil
        }
        .sheet(isPresented: Binding(
            get: { selectedTaskID != nil },
            set: { presented in if !presented { selectedTaskID = nil } }
        )) {
            taskDetailSheet
        }
        .sheet(isPresented: $presentingAddWorkspace) {
            AddWorkspaceSheet(store: store)
        }
        .sheet(item: $addProjectTarget) { ws in
            AddProjectSheet(store: store, workspace: ws)
        }
        .sheet(isPresented: $showSetup) {
            OnboardingView()
        }
        .task { evaluateOnboarding() }
        .onChange(of: onboardingReopen) { _, requested in
            if requested {
                showSetup = true
                onboardingReopen = false
            }
        }
        .tint(Color.atelierAccent)
        .foregroundStyle(Color.atelierInk)
    }

    @ViewBuilder
    private var taskDetailSheet: some View {
        if let task = selectedTask {
            Group {
                if let run = spawner.activeRun(for: task.id) {
                    TaskAgentView(store: store,
                                  spawner: spawner,
                                  task: task,
                                  run: run,
                                  onClose: { selectedTaskID = nil })
                } else {
                    TaskDetailView(store: store,
                                   spawner: spawner,
                                   server: server,
                                   approvalQueue: approvalQueue,
                                   task: task,
                                   selectedProject: selectedProject,
                                   onClear: { selectedTaskID = nil })
                }
            }
            .frame(minWidth: 1000, idealWidth: 1100, maxWidth: 1500,
                   minHeight: 700, idealHeight: 820, maxHeight: 1200)
        }
    }

    @ViewBuilder
    private var centerView: some View {
        switch centerTarget {
        case .swarm:
            SwarmView(store: store, spawner: spawner, server: server, approvalQueue: approvalQueue) { _, taskId in
                // Open the task sheet directly without leaving the Swarm view.
                // selectedProject is derived from the task's own projectId below
                // so we don't lose context (or change column targets) on every click.
                selectedTaskID = taskId
            }
            .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        case .approvals:
            ApprovalsView(queue: approvalQueue,
                          store: store,
                          onOpenTask: { taskId in selectedTaskID = taskId })
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        case .usage:
            UsageDashboardView(store: store)
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        case .chat:
            ChatsView(store: store, spawner: chatSpawner)
                .navigationSplitViewColumnWidth(min: 720, ideal: 1000)
        case .project(let id):
            BacklogPane(store: store,
                        spawner: spawner,
                        server: server,
                        approvalQueue: approvalQueue,
                        featureRunner: featureRunner,
                        selectedProjectID: id,
                        selectedTaskID: $selectedTaskID)
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        case nil:
            BacklogPane(store: store,
                        spawner: spawner,
                        server: server,
                        approvalQueue: approvalQueue,
                        featureRunner: featureRunner,
                        selectedProjectID: nil,
                        selectedTaskID: $selectedTaskID)
                .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        }
    }

    private var selectedTask: AtelierTask? {
        guard let id = selectedTaskID else { return nil }
        return store.taskByID(id)
    }

    private var selectedProject: Project? {
        // 1. If we're on a project's kanban, that's the project.
        if case .project(let id) = centerTarget,
           let p = store.projectByID(id) {
            return p
        }
        // 2. Otherwise (Swarm view, no center), resolve via the selected task.
        if let task = selectedTask,
           let p = store.projectByID(task.projectId) {
            return p
        }
        return nil
    }

    private func evaluateOnboarding() {
        // Show the setup assistant on first launch, and whenever the hard prerequisites
        // (claude + git) are missing — without them nothing can spawn.
        guard !showSetup else { return }
        if !onboardingCompleted || !PreflightService.check().hardRequirementsMet {
            showSetup = true
        }
    }
}
