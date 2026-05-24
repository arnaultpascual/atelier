// SPDX-License-Identifier: MIT
import SwiftUI

/// Sidebar listing workspaces and their projects.
///
/// Uses a custom LazyVStack rather than `List` so we own the spacing, the foldable
/// section behaviour, and the row hit-targets. Selection is by project id; foldable
/// state per workspace persists via `@AppStorage`.
struct WorkspaceSidebar: View {
    @Bindable var store: AppStore
    @Bindable var server: ApprovalServer
    @Bindable var spawner: TaskSpawner
    @Bindable var approvalQueue: ApprovalQueue
    @Binding var centerTarget: MainView.CenterTarget?
    let onAddWorkspace: () -> Void
    let onAddProject: (Workspace) -> Void

    private var selectedProjectID: String? {
        if case .project(let id) = centerTarget { return id }
        return nil
    }

    /// JSON-encoded list of workspace ids the user has collapsed.
    @AppStorage("sidebar.collapsedWorkspaceIDs") private var collapsedJSON: String = "[]"
    @State private var hoveredProjectID: String?

    private var collapsed: Set<String> {
        get {
            (try? JSONDecoder().decode([String].self, from: Data(collapsedJSON.utf8))).map(Set.init) ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            trafficLightReserve
            brandRow
            Divider().background(Color.atelierDivider).opacity(0.6)
            chatShortcut
            swarmShortcut
            approvalsShortcut
            usageShortcut
            Divider().background(Color.atelierDivider).opacity(0.6)
            list
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .background(Color.atelierBackground)
    }

    private var chatShortcut: some View {
        let isSelected: Bool = {
            if case .chat = centerTarget { return true }
            return false
        }()
        return Button {
            centerTarget = .chat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.atelierAccent : Color.atelierInkSecondary)
                Text("Chat")
                    .font(AtelierFont.callout.weight(.medium))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                if store.chatRooms.isEmpty {
                    Text("new")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.6))
                } else {
                    Text("\(store.chatRooms.count)")
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.atelierAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Free-form Claude conversations — no project, no worktree.")
    }

    private var usageShortcut: some View {
        let isSelected: Bool = {
            if case .usage = centerTarget { return true }
            return false
        }()
        return Button {
            centerTarget = .usage
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.atelierAccent : Color.atelierInkSecondary)
                Text("Usage")
                    .font(AtelierFont.callout.weight(.medium))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                Text("$ · tokens")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.atelierAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Cross-project usage dashboard — cost + tokens by window and model.")
    }

    private var approvalsShortcut: some View {
        let pendingCount = approvalQueue.pendingCount
        let isSelected: Bool = {
            if case .approvals = centerTarget { return true }
            return false
        }()
        return Button {
            centerTarget = .approvals
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pendingCount > 0 ? "bell.badge.fill" : "bell")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(pendingCount > 0
                                     ? Color.atelierAccent
                                     : (isSelected ? Color.atelierAccent : Color.atelierInkSecondary))
                Text("Approvals")
                    .font(AtelierFont.callout.weight(.medium))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(AtelierFont.captionMono.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.atelierAccent, in: Capsule())
                } else {
                    Text("idle")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.atelierAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help(pendingCount > 0
              ? "\(pendingCount) tool call(s) pending your approval."
              : "Approvals queue.")
    }

    private var swarmShortcut: some View {
        Button {
            centerTarget = .swarm
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSwarmSelected ? Color.atelierAccent : Color.atelierInkSecondary)
                Text("Swarm")
                    .font(AtelierFont.callout.weight(.medium))
                    .foregroundStyle(Color.atelierInk)
                Spacer()
                liveAgentBadge
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSwarmSelected
                    ? Color.atelierAccent.opacity(0.12)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Cross-project overview of every running worker.")
    }

    @ViewBuilder
    private var liveAgentBadge: some View {
        let liveCount = spawner.runs.values.filter { !$0.agent.status.isTerminal }.count
        let total = spawner.runs.count
        let totalCost = spawner.runs.values.reduce(0) { $0 + $1.state.totalCostUsd }
        if liveCount > 0 {
            HStack(spacing: 4) {
                Circle().fill(Color.atelierAccent).frame(width: 5, height: 5)
                Text("\(liveCount)")
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
                if totalCost > 0 {
                    Text(String(format: "$%.4f", totalCost))
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
        } else if total > 0 {
            Text("\(total)")
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    private var isSwarmSelected: Bool {
        if case .swarm = centerTarget { return true }
        return false
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: AtelierLayout.paneHeaderTopReserve)
    }

    private var brandRow: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            Text("Atelier")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: AtelierLayout.paneHeaderContentHeight)
    }

    @ViewBuilder
    private var list: some View {
        if store.workspaces.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.workspaces) { ws in
                        WorkspaceSection(
                            workspace: ws,
                            projects: store.projects(in: ws.id),
                            isExpanded: !collapsed.contains(ws.id),
                            selectedProjectID: selectedProjectID,
                            hoveredProjectID: $hoveredProjectID,
                            onSelectProject: { id in centerTarget = .project(id) },
                            onToggle: { toggleCollapsed(ws.id) },
                            onAddProject: { onAddProject(ws) },
                            onRecolor: { hex in
                                Task { try? await store.recolorWorkspace(ws, to: hex) }
                            },
                            onDelete: {
                                Task { try? await store.deleteWorkspace(ws) }
                            },
                            onDeleteProject: { p in
                                Task { try? await store.deleteProject(p) }
                            },
                            onRevealProject: revealInFinder
                        )
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 18)
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 4) {
                Text("Start with a workspace")
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                Text("A workspace groups projects by client\nor context. Pick a name and a colour.")
                    .multilineTextAlignment(.center)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
            }
            Button(action: onAddWorkspace) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New workspace")
                        .font(.system(.callout).weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            }
            .buttonStyle(.plain)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onAddWorkspace) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Workspace")
                        .font(AtelierFont.caption.weight(.medium))
                }
                .foregroundStyle(Color.atelierInkSecondary)
            }
            .buttonStyle(.plain)
            .help("Create a new workspace")

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(server.helperReady ? Palette.success : Palette.stoneLight)
                    .frame(width: 6, height: 6)
                Text(server.helperReady ? "MCP · helper" : "MCP · missing")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .help("Stdio MCP helper bundled at Atelier.app/Contents/MacOS/AtelierApprovalHelper.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toggleCollapsed(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        if let data = try? JSONEncoder().encode(Array(set).sorted()),
           let str = String(data: data, encoding: .utf8) {
            collapsedJSON = str
        }
    }

    private func revealInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }
}

// MARK: - Workspace section

private struct WorkspaceSection: View {
    let workspace: Workspace
    let projects: [Project]
    let isExpanded: Bool
    let selectedProjectID: String?
    @Binding var hoveredProjectID: String?
    let onSelectProject: (String) -> Void
    let onToggle: () -> Void
    let onAddProject: () -> Void
    let onRecolor: (String) -> Void
    let onDelete: () -> Void
    let onDeleteProject: (Project) -> Void
    let onRevealProject: (Project) -> Void

    @State private var showColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(projects) { p in
                        ProjectRow(
                            project: p,
                            isSelected: selectedProjectID == p.id,
                            isHovered: hoveredProjectID == p.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectProject(p.id) }
                        .onHover { hovering in
                            hoveredProjectID = hovering ? p.id : (hoveredProjectID == p.id ? nil : hoveredProjectID)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { onRevealProject(p) }
                            Divider()
                            Button("Remove from Atelier", role: .destructive) { onDeleteProject(p) }
                        }
                    }
                    AddProjectButton(onTap: onAddProject)
                }
                .padding(.leading, 6)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.atelierInkSecondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            Button {
                showColorPicker = true
            } label: {
                Circle()
                    .fill(Color(hex: workspace.color))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.atelierInk.opacity(0.12), lineWidth: 1))
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColorPicker, arrowEdge: .leading) {
                ColorChoicePopover(currentHex: workspace.color) { hex in
                    onRecolor(hex)
                    showColorPicker = false
                }
            }
            .help("Change colour")

            Text(workspace.name.uppercased())
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInk)

            if !projects.isEmpty {
                Text("\(projects.count)")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
            }

            Spacer()

            WorkspaceMenu(
                workspace: workspace,
                onAddProject: onAddProject,
                onDelete: onDelete
            )
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onTapGesture { onToggle() }
    }
}

// MARK: - Color picker popover

private struct ColorChoicePopover: View {
    let currentHex: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace colour")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            HStack(spacing: 6) {
                ForEach(Workspace.colorChoices, id: \.hex) { choice in
                    Dot(hex: choice.hex,
                        name: choice.name,
                        isSelected: choice.hex.caseInsensitiveCompare(currentHex) == .orderedSame,
                        onTap: { onPick(choice.hex) })
                }
            }
        }
        .padding(14)
    }

    private struct Dot: View {
        let hex: String
        let name: String
        let isSelected: Bool
        let onTap: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: onTap) {
                ZStack {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .stroke(Color.atelierInk, lineWidth: 2)
                            .frame(width: 28, height: 28)
                    } else if hover {
                        Circle()
                            .stroke(Color.atelierInk.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                    }
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(name)
        }
    }
}

// MARK: - Workspace menu (just non-colour actions now)

private struct WorkspaceMenu: View {
    let workspace: Workspace
    let onAddProject: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        Menu {
            Button {
                onAddProject()
            } label: {
                Label("Add project…", systemImage: "folder.badge.plus")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete workspace", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Color.atelierInk : Color.atelierInkSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .onHover { hover = $0 }
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: Project
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(isSelected ? Color.atelierAccent : Color.atelierInkSecondary)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(AtelierFont.body)
                    .foregroundStyle(Color.atelierInk)
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .padding(.leading, 4)
    }

    private var rowBackground: Color {
        if isSelected { return Color.atelierAccent.opacity(0.18) }
        if isHovered { return Color.atelierSurface }
        return .clear
    }
}

// MARK: - Add project button

private struct AddProjectButton: View {
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                Text("Add project")
                    .font(AtelierFont.caption.weight(.medium))
            }
            .foregroundStyle(hover ? Color.atelierAccent : Color.atelierInkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.leading, 4)
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var num: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&num)
        let r = Double((num & 0xFF0000) >> 16) / 255
        let g = Double((num & 0x00FF00) >> 8) / 255
        let b = Double(num & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
