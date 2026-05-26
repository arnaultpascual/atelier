// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-page Chat center. Left rail = list of rooms, right pane = the
/// selected conversation. New chats are created on-demand from the toolbar.
struct ChatsView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: ChatSpawner

    @State private var selectedRoomId: String?

    var body: some View {
        HStack(spacing: 0) {
            roomsRail
            Divider().background(Color.atelierDivider).opacity(0.6)
            roomPane
        }
        .background(Color.atelierBackground)
        .task { await ensureSelection() }
        .onChange(of: store.chatRooms.count) { _, _ in
            Task { await ensureSelection() }
        }
    }

    // MARK: Rooms rail

    private var roomsRail: some View {
        VStack(spacing: 0) {
            trafficLightReserve
            railHeader
            Divider().background(Color.atelierDivider).opacity(0.5)
            if store.chatRooms.isEmpty {
                emptyRail
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.chatRooms) { room in
                            roomRow(room)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 260)
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: AtelierLayout.paneHeaderTopReserve)
    }

    private var railHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chat")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("\(store.chatRooms.count) conversation\(store.chatRooms.count == 1 ? "" : "s")")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Button(action: newChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.atelierAccent)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new conversation")
            .keyboardShortcut("n", modifiers: [.command])
        }
        .padding(.horizontal, 14)
        .frame(height: AtelierLayout.paneHeaderContentHeight)
    }

    private func roomRow(_ room: ChatRoom) -> some View {
        let isSelected = selectedRoomId == room.id
        return Button {
            selectedRoomId = room.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    TypewriterText(text: room.title,
                                   font: AtelierFont.callout.weight(.medium),
                                   color: Color.atelierInk)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(room.updatedAt.formatted(.relative(presentation: .named)))
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(Color.atelierInkSecondary)
                        if room.costUsd > 0 {
                            Text(String(format: "$%.4f", room.costUsd))
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierAccent.opacity(0.8))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.atelierAccent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                deleteChat(room)
            } label: {
                Label("Delete chat", systemImage: "trash")
            }
        }
    }

    private var emptyRail: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
            Text("No conversations yet")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Button(action: newChat) {
                Text("Start a chat")
                    .font(AtelierFont.caption.weight(.medium))
            }
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Room pane

    @ViewBuilder
    private var roomPane: some View {
        if let id = selectedRoomId, let room = store.chatRoom(id: id) {
            ChatRoomView(
                room: room,
                store: store,
                spawner: spawner
            )
            .id(room.id)   // reset state on selection change
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.atelierAccent.opacity(0.7))
                Text("Start a conversation")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                Text("Free-form Claude — no worktree, no git. Pure conversation: brainstorm, draft, ask. Tools are off so it can't read or modify files.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .multilineTextAlignment(.center)
                Button(action: newChat) {
                    Text("New chat").fontWeight(.semibold)
                }
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: [.command])
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    // MARK: Actions

    private func ensureSelection() async {
        if let id = selectedRoomId, store.chatRoom(id: id) != nil { return }
        if let first = store.chatRooms.first {
            selectedRoomId = first.id
        }
    }

    private func newChat() {
        Task {
            do {
                let room = try await store.createChatRoom()
                await MainActor.run { selectedRoomId = room.id }
            } catch {
                // Logged inside the store.
            }
        }
    }

    private func deleteChat(_ room: ChatRoom) {
        Task {
            try? await store.deleteChatRoom(room)
            await MainActor.run {
                if selectedRoomId == room.id { selectedRoomId = nil }
            }
        }
    }
}

// MARK: - Room view

private struct ChatRoomView: View {
    let room: ChatRoom
    @Bindable var store: AppStore
    @Bindable var spawner: ChatSpawner

    @State private var draft: String = ""
    @State private var historyEvents: [StreamEvent] = []
    @State private var historyMessages: [ChatMessage] = []
    @State private var historyLoaded: Bool = false
    @State private var detailMode: Bool = false
    @State private var attachments: [URL] = []
    @State private var webEnabled: Bool = false
    @State private var contextPath: String? = nil
    @State private var capsLoaded: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showCreateTask = false
    @State private var ctProjectId: String = ""
    @State private var ctTitle: String = ""
    @State private var ctDesc: String = ""

    private var liveTurn: LiveChatTurn? { spawner.turn(for: room.id) }
    private var allProjects: [Project] {
        store.projectsByWorkspace.values.flatMap { $0 }.sorted { $0.name < $1.name }
    }
    private var isWorking: Bool { spawner.isBusy(roomId: room.id) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: AtelierLayout.paneHeaderTopReserve)
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            conversation
            Divider().background(Color.atelierDivider).opacity(0.6)
            inputBar
        }
        .task { await loadHistoryIfNeeded() }
        .sheet(isPresented: $showCreateTask) { createTaskSheet }
    }

    private func prepareCreateTask() {
        ctTitle = room.title == "Untitled chat" ? "" : room.title
        ctDesc = ""
        if ctProjectId.isEmpty || !allProjects.contains(where: { $0.id == ctProjectId }) {
            ctProjectId = allProjects.first?.id ?? ""
        }
        showCreateTask = true
    }

    private func createTaskFromChat() {
        guard let project = allProjects.first(where: { $0.id == ctProjectId }) else { return }
        let title = ctTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let desc = ctDesc
        Task {
            do {
                var task = try await store.createTask(in: project, title: title)
                if !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    task.descriptionMd = desc
                    try await store.updateTask(task)
                }
                await MainActor.run { showCreateTask = false }
            } catch {
                // best-effort: leave the sheet open so the user can retry
            }
        }
    }

    @ViewBuilder
    private var createTaskSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create task from chat")
                .font(AtelierFont.title)
                .foregroundStyle(Color.atelierInk)
            if allProjects.isEmpty {
                Text("Add a project first — tasks live in a project's backlog.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("PROJECT")
                    Picker("", selection: $ctProjectId) {
                        ForEach(allProjects) { p in Text(p.name).tag(p.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("TITLE")
                    TextField("Task title", text: $ctTitle).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("DESCRIPTION (optional)")
                    TextEditor(text: $ctDesc)
                        .scrollContentBackground(.hidden)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                    Text("The worker won't see this chat — paste any conclusions you want it to act on.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showCreateTask = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create task") { createTaskFromChat() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ctProjectId.isEmpty || ctTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .background(Color.atelierBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TypewriterText(text: room.title,
                               font: .system(.title3, design: .serif).weight(.semibold),
                               color: Color.atelierInk)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if room.costUsd > 0 {
                        Text(String(format: "$%.4f", room.costUsd))
                            .font(AtelierFont.captionMono.weight(.semibold))
                            .foregroundStyle(Color.atelierAccent)
                    }
                    if let sid = room.sessionId {
                        Menu {
                            Button {
                                let url = SessionReader.sessionFileURL(cwd: room.scratchPath, sessionId: sid)
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            } label: { Label("Reveal session log in Finder", systemImage: "folder") }
                            Button {
                                copyToPasteboard("cd \"\(room.scratchPath)\" && claude --resume \(sid)")
                            } label: { Label("Copy resume command", systemImage: "terminal") }
                            Button {
                                copyToPasteboard(SessionReader.sessionFileURL(cwd: room.scratchPath, sessionId: sid).path)
                            } label: { Label("Copy session log path", systemImage: "doc.on.doc") }
                            Button {
                                copyToPasteboard(sid)
                            } label: { Label("Copy session ID", systemImage: "number") }
                        } label: {
                            Text("· session \(String(sid.prefix(8)))…")
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Recover this session outside the app")
                    }
                }
            }
            Spacer()
            Button { prepareCreateTask() } label: {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(allProjects.isEmpty)
            .help(allProjects.isEmpty ? "Add a project first to create tasks." : "Create a task in a project from this chat")
            viewModeToggle
            modelPicker
            if isWorking {
                Button(action: { spawner.cancel(roomId: room.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(AtelierFont.caption)
                    }
                    .foregroundStyle(Palette.error)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atelierSurface, in: Capsule())
                    .overlay(Capsule().stroke(Palette.error.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: AtelierLayout.paneHeaderContentHeight)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 0) {
            modePill(label: "Chat", selected: !detailMode) { detailMode = false }
            modePill(label: "Detail", selected: detailMode) { detailMode = true }
        }
        .padding(2)
        .background(Color.atelierSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
    }

    private func modePill(label: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(label)
                .font(AtelierFont.captionMono.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.atelierAccent : Color.atelierInkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.atelierAccentSoft.opacity(0.7) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var modelPicker: some View {
        Menu {
            ForEach(ModelRouter.Model.allCases, id: \.rawValue) { m in
                Button(action: { changeModel(m.rawValue) }) {
                    HStack {
                        if m.rawValue == room.model {
                            Image(systemName: "checkmark")
                        }
                        Text(m.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                Text(modelLabel(room.model))
                    .font(AtelierFont.captionMono.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.atelierInkSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.atelierSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model used for the next message. Click to change.")
    }

    private func modelLabel(_ raw: String) -> String {
        ModelRouter.Model(rawValue: raw)?.displayName ?? raw
    }

    private func changeModel(_ newId: String) {
        var updated = room
        updated.model = newId
        Task { try? await store.updateChatRoom(updated) }
    }

    @ViewBuilder
    private var conversation: some View {
        if detailMode {
            detailConversation
        } else {
            chatConversation
        }
    }

    /// Default rendering: user / assistant bubbles, no system or rate-limit
    /// noise. Clean conversational look.
    private var chatConversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(combinedMessages) { msg in
                        ChatBubble(message: msg)
                            .id(msg.id)
                    }
                    if isWorking {
                        workingIndicator.id("working")
                    }
                    if let err = liveTurn?.lastErrorMessage, !err.isEmpty, !isWorking {
                        errorBanner(err)
                    }
                    if combinedMessages.isEmpty && !isWorking && (liveTurn?.lastErrorMessage ?? "").isEmpty {
                        emptyHint
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: combinedMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if isWorking {
                        proxy.scrollTo("working", anchor: .bottom)
                    } else if let last = combinedMessages.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Detail rendering: every stream-json event raw — useful for debugging
    /// or reading the system init / rate-limit / result lines.
    private var detailConversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(combinedEvents) { event in
                        EventCardRow(event: event)
                            .id(event.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        workingIndicator.id("working")
                    }
                    if let err = liveTurn?.lastErrorMessage, !err.isEmpty, !isWorking {
                        errorBanner(err)
                    }
                    if combinedEvents.isEmpty && !isWorking && (liveTurn?.lastErrorMessage ?? "").isEmpty {
                        emptyHint
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: combinedEvents.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if isWorking {
                        proxy.scrollTo("working", anchor: .bottom)
                    } else if let last = combinedEvents.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var combinedMessages: [ChatMessage] {
        let live = liveTurn?.messages ?? []
        return historyMessages + live
    }

    private var combinedEvents: [StreamEvent] {
        var out = historyEvents
        if let live = liveTurn?.events {
            let known = Set(out.map(\.id))
            out.append(contentsOf: live.filter { !known.contains($0.id) })
        }
        return out
    }

    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("claude is thinking…")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
        }
        .padding(12)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.error)
            Text(message)
                .font(AtelierFont.caption)
                .foregroundStyle(Palette.error)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .background(Palette.error.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.error.opacity(0.4), lineWidth: 1))
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.4))
            Text("Empty conversation — say something to start.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // Claude-style composer: a single rounded box — attachment thumbnails on top,
    // the text field in the middle, a controls row (+ menu · context · web · send)
    // along the bottom.
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty { attachmentPreviews }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .default))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 40, maxHeight: 150)
                    .disabled(isWorking)
                if draft.isEmpty {
                    Text(isWorking ? "Waiting for claude to finish…" : "Write a message…  ⌘↩ to send")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            composerControls
        }
        .padding(12)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.atelierAccent : Color.atelierDivider,
                        lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleChatDrop(providers: providers)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .onAppear {
            guard !capsLoaded else { return }
            capsLoaded = true
            webEnabled = UserDefaults.standard.bool(forKey: webPrefKey)
            contextPath = UserDefaults.standard.string(forKey: ctxPrefKey)
        }
        .onChange(of: webEnabled) { _, value in
            UserDefaults.standard.set(value, forKey: webPrefKey)
        }
    }

    private var composerControls: some View {
        HStack(spacing: 8) {
            chatPlusMenu
            contextChip
            if webEnabled { webBadge }
            Spacer(minLength: 8)
            sendButton
        }
    }

    private var sendReady: Bool {
        !isWorking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(sendReady ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!sendReady)
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Send (⌘↩)")
    }

    // MARK: Chat capabilities (attachments / web / project context)

    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { url in
                    attachmentPreview(url)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func attachmentPreview(_ url: URL) -> some View {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
        let isImage = imageExts.contains(url.pathExtension.lowercased())
        return ZStack(alignment: .topTrailing) {
            Group {
                if isImage, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.fill").font(.system(size: 14))
                        Text(url.pathExtension.uppercased().isEmpty ? "FILE" : url.pathExtension.uppercased())
                            .font(.system(size: 7, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 46, height: 46)
                    .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider, lineWidth: 1))
            Button { attachments.removeAll { $0 == url } } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .help(url.lastPathComponent)
    }

    /// Directory/context selector, styled like Claude Code's folder chip.
    private var contextChip: some View {
        Menu {
            if contextPath != nil {
                Button { pickContextFolder() } label: { Label("Change folder…", systemImage: "folder") }
                Button(role: .destructive) { clearContext() } label: { Label("Remove context", systemImage: "xmark.circle") }
            } else {
                Button { pickContextFolder() } label: { Label("Choose a project folder…", systemImage: "folder") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: contextPath == nil ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 10))
                Text(contextPath.map { ($0 as NSString).lastPathComponent } ?? "Context")
                    .font(AtelierFont.captionMono).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(contextPath == nil ? Color.atelierInkSecondary : Color.atelierAccent)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(contextPath == nil ? Color.atelierSurface : Color.atelierAccentSoft.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(contextPath == nil ? Color.atelierDivider : Color.atelierAccent.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(contextPath ?? "Give claude read access to a project folder (Read/Glob/Grep)")
    }

    private var webBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe").font(.system(size: 10))
            Text("Web").font(AtelierFont.captionMono)
        }
        .foregroundStyle(Color.atelierAccent)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.atelierAccentSoft.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(Color.atelierAccent.opacity(0.4), lineWidth: 1))
    }

    /// "+" composer menu mirroring Claude's chat menu: attach, web search, project context.
    private var chatPlusMenu: some View {
        Menu {
            Button { pickChatAttachments() } label: {
                Label("Add files or photos", systemImage: "paperclip")
            }
            Toggle(isOn: $webEnabled) {
                Label("Web search", systemImage: "globe")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.atelierInkSecondary)
                .frame(width: 30, height: 30)
                .background(Color.atelierSurface, in: Circle())
                .overlay(Circle().stroke(Color.atelierDivider, lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add files or photos · Web search")
    }

    private var webPrefKey: String { "chat.web.\(room.id)" }
    private var ctxPrefKey: String { "chat.ctx.\(room.id)" }

    private func pickChatAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach to this message"
        if panel.runModal() == .OK {
            for url in panel.urls where !attachments.contains(where: { $0.path == url.path }) {
                attachments.append(url)
            }
        }
    }

    /// Drag-and-drop files/images straight onto the composer.
    private func handleChatDrop(providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            anyHandled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if !attachments.contains(where: { $0.path == url.path }) {
                        attachments.append(url)
                    }
                }
            }
        }
        return anyHandled
    }

    private func pickContextFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Give claude read access to a project folder"
        if panel.runModal() == .OK, let url = panel.urls.first {
            contextPath = url.path
            UserDefaults.standard.set(url.path, forKey: ctxPrefKey)
        }
    }

    private func clearContext() {
        contextPath = nil
        UserDefaults.standard.removeObject(forKey: ctxPrefKey)
    }

    private func send() {
        let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !isWorking else { return }
        spawner.send(room: room,
                     message: msg,
                     store: store,
                     attachments: attachments,
                     allowWeb: webEnabled,
                     contextPath: contextPath)
        draft = ""
        attachments = []
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Loads disk-persisted events from claude's JSONL the first time we
    /// open a room with prior turns. Skipped when there's an in-memory
    /// liveTurn (it already has the events).
    private func loadHistoryIfNeeded() async {
        guard !historyLoaded else { return }
        defer { historyLoaded = true }
        guard liveTurn == nil, let sid = room.sessionId else { return }
        if let events = SessionReader.loadEvents(cwd: room.scratchPath, sessionId: sid) {
            historyEvents = events
        }
        historyMessages = ChatJSONLReader.messages(cwd: room.scratchPath, sessionId: sid)
    }
}

// MARK: - Chat bubble

/// Clean conversational bubble (user accent / assistant markdown). Shared by the
/// Chat view and the Review section's "Chat" conversation mode.
struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: alignment, spacing: 4) {
                bubbleContent
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.6))
                    .padding(.horizontal, 4)
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(.body))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 560, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .assistant:
            MarkdownView(source: message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 720, alignment: .leading)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.atelierDivider.opacity(0.4), lineWidth: 1)
                )
        }
    }
}

// MARK: - Chat history reader

/// Pulls user prompts + assistant text out of claude's persisted JSONL.
/// Used to repopulate the chat view's bubbles after relaunch.
enum ChatJSONLReader {
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func messages(cwd: String, sessionId: String) -> [ChatMessage] {
        let url = SessionReader.sessionFileURL(cwd: cwd, sessionId: sessionId)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [ChatMessage] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = parseTimestamp(obj["timestamp"] as? String)
            let type = obj["type"] as? String
            switch type {
            case "user":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let s = msg["content"] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        out.append(ChatMessage(role: .user, text: trimmed, at: ts))
                    }
                }
                // Array content here = tool_results; skip — not user-typed.
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                var text = ""
                for block in blocks where (block["type"] as? String) == "text" {
                    if let t = block["text"] as? String {
                        if !text.isEmpty { text += "\n" }
                        text += t
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out.append(ChatMessage(role: .assistant, text: trimmed, at: ts))
                }
            default:
                break
            }
        }
        return out
    }

    private static func parseTimestamp(_ s: String?) -> Date {
        guard let s else { return Date() }
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        return Date()
    }
}

// MARK: - Typewriter

/// Animates a string change like it's being typed. Used for room titles so
/// the rename after the first message reads as production, not refresh.
struct TypewriterText: View {
    let text: String
    let font: Font
    let color: Color
    var perCharacterSeconds: Double = 0.025

    @State private var displayed: String = ""
    @State private var animatingTask: Task<Void, Never>?

    var body: some View {
        Text(displayed.isEmpty ? " " : displayed)
            .font(font)
            .foregroundStyle(color)
            .onAppear { animateTo(text) }
            .onChange(of: text) { _, newValue in
                animateTo(newValue)
            }
    }

    private func animateTo(_ target: String) {
        animatingTask?.cancel()
        if displayed == target { return }
        // If the target shrinks (e.g. delete), just snap.
        if !target.hasPrefix(displayed) {
            displayed = ""
        }
        let from = displayed.count
        let to = target.count
        guard to > from else { displayed = target; return }
        animatingTask = Task { @MainActor in
            for i in (from + 1)...to {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(perCharacterSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                displayed = String(target.prefix(i))
            }
        }
    }
}
