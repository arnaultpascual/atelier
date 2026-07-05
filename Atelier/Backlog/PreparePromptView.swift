// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Prepare prompt" workspace — an iterative, persistent space (one per feature) where you
/// gather context (pinned folders, links, files/images) and co-author a precise brief with
/// Claude, then hand it to Fill Kanban. Backed by a project-scoped "brief" chat room, so the
/// conversation and pinned context survive across app launches (the session is resumable).
struct PreparePromptView: View {
    @Bindable var store: AppStore
    @Bindable var chatSpawner: ChatSpawner
    let project: Project
    /// When set, the view works on this single brief only — no brief picker / New / Close / "Send to
    /// Fill kanban" chrome and no fixed sheet frame — so it can be embedded inline (e.g. inside the
    /// feature flow's Brief stage). nil = the standalone sheet behaviour.
    var pinnedBriefId: String? = nil
    /// The feature this brief belongs to (embedded feature flow). Enables the persistent
    /// shared-files store: attachments sent with a message are also copied into
    /// `.atelier/attachments/feature-<id>/` so decompose can route them to tasks.
    var featureId: String? = nil
    /// (briefText, attachments, inspectRepo) → seeds the Fill Kanban compose screen. Unused when embedded.
    var onSendToFillKanban: (String, [URL], Bool) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}

    private var embedded: Bool { pinnedBriefId != nil }

    @State private var selectedBriefId: String?
    @State private var draft: String = ""
    @State private var briefEditing: String = ""
    // Embedded (feature flow): the brief is a LIVE FILE (`brief.md` in the room scratch dir) that
    // Claude edits as the conversation evolves — we render it read-only, no copy-paste.
    @State private var briefFileContent: String = ""
    @State private var briefPreviewCollapsed: Bool = false
    @State private var attachments: [URL] = []
    // Feature-level shared files (persisted in .atelier/attachments/feature-<id>/).
    @State private var sharedFiles: [URL] = []
    @State private var sharedFilesCollapsed = false
    @State private var sharedFilesNote: String?   // store-failure feedback (never silent)
    @State private var webEnabled: Bool = false
    @State private var newLink: String = ""
    @State private var historyMessages: [ChatMessage] = []
    // Multi-pass refinement loop: each pass critiques + rewrites the brief and emits a convergence
    // signal; the loop stops on stability (no open questions, no material change), a pass cap, or a
    // user stop. Driven off `onChange(of: liveRunning)` so it reuses the brief's resumable session.
    @State private var refining: Bool = false
    @State private var refinePass: Int = 0
    @State private var refineStop: Bool = false
    @State private var refineConverged: Bool = false
    @State private var refineStatus: String = ""
    @State private var refinePrevBrief: String = ""
    private let maxRefinePasses = 4

    private var profile: ProjectProfile { ProjectProfile.find(id: project.profileId) ?? .generic }
    private var selectedRoom: ChatRoom? {
        guard let id = selectedBriefId else { return nil }
        return store.chatRoom(id: id)
    }
    private var liveTurn: LiveChatTurn? { chatSpawner.turn(for: selectedBriefId ?? "") }
    private var liveRunning: Bool { liveTurn?.isRunning ?? false }
    private var messages: [ChatMessage] {
        if let lt = liveTurn, !lt.messages.isEmpty { return lt.messages }
        return historyMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                header
                Divider().background(Color.atelierDivider).opacity(0.6)
            }
            HStack(spacing: 0) {
                conversationPane
                Divider().background(Color.atelierDivider).opacity(0.6)
                contextAndBriefRail.frame(width: 330)
            }
        }
        .modifier(EmbeddableFrame(embedded: embedded))
        .background(Color.atelierBackground)
        .onAppear { ensureBrief(); reloadSharedFiles() }
        .onDisappear { persistBrief() }   // keep manual brief edits on close
        .onChange(of: store.briefRevision[pinnedBriefId ?? ""]) { _, _ in
            // The MCP bridge wrote brief.md via a brief_* tool — refresh live.
            if embedded { loadBriefFile() }
        }
        .onChange(of: liveRunning) { _, running in
            guard !running else { return }
            // Claude may have edited brief.md this turn — refresh the live preview.
            if embedded { loadBriefFile() }
            // A refinement pass just finished — judge convergence, loop or stop.
            if refining { handleRefinePassFinished() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.append").foregroundStyle(Color.atelierAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Prepare prompt").font(AtelierFont.title).foregroundStyle(Color.atelierInk)
                Text(project.name).font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            briefPicker
            Button(action: createBrief) {
                Label("New", systemImage: "plus").font(AtelierFont.caption.weight(.medium))
            }
            .help("Start a fresh brief for another feature.")
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var briefPicker: some View {
        Menu {
            ForEach(store.briefRooms(in: project.id)) { room in
                Button {
                    selectBrief(room)
                } label: {
                    Label(room.title, systemImage: room.id == selectedBriefId ? "checkmark" : "doc.text")
                }
            }
            if store.briefRooms(in: project.id).isEmpty {
                Text("No briefs yet").foregroundStyle(Color.atelierInkSecondary)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.system(size: 10))
                Text(selectedRoom?.title ?? "Brief").font(AtelierFont.captionMono).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(Color.atelierInk)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.atelierSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    // MARK: Conversation

    private var conversationPane: some View {
        VStack(spacing: 0) {
            if messages.isEmpty && !liveRunning {
                emptyConversation
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { ChatBubble(message: $0) }
                        if liveRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is thinking…").font(AtelierFont.caption)
                                    .foregroundStyle(Color.atelierInkSecondary)
                                Button("Stop") {
                                    if let id = selectedBriefId { chatSpawner.cancel(roomId: id) }
                                }
                                .controlSize(.small)
                                .help("Interrompre le tour en cours (le brief.md déjà écrit est conservé).")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
            if let err = liveTurn?.lastErrorMessage {
                CalloutBanner(.danger, err).padding(.horizontal, 16).padding(.bottom, 6)
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 28)).foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
            Text("Describe the feature and pin context")
                .font(AtelierFont.subtitle).foregroundStyle(Color.atelierInk)
            Text("Bring everything that defines the feature — a functional spec (what it should do), a technical brief (constraints, stack), reference links, screenshots/mockups, and spec files. Pin the codebase folders it touches so the brief and tasks reference real files. Claude asks questions, then Refine converges a testable, TDD-ready brief you send to Fill kanban.")
                .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                inputHint("doc.text", "Spec / brief")
                inputHint("photo", "Images")
                inputHint("link", "Links")
                inputHint("folder", "Codebase")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func inputHint(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(AtelierFont.eyebrow)
        }
        .foregroundStyle(Color.atelierInkSecondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.atelierSurface.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextEditor(text: $draft)
                .scrollContentBackground(.hidden)
                .font(.system(.body))
                .frame(minHeight: 44, maxHeight: 130)
                .padding(8)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.atelierDivider, lineWidth: 1))
                .disabled(liveRunning)
            HStack(spacing: 8) {
                Menu {
                    Button { pickAttachments() } label: { Label("Add files or photos", systemImage: "paperclip") }
                    Toggle(isOn: $webEnabled) { Label("Web search", systemImage: "globe") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.atelierSurface, in: Circle())
                        .overlay(Circle().stroke(Color.atelierDivider, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if !attachments.isEmpty {
                    Text("\(attachments.count) file\(attachments.count == 1 ? "" : "s")")
                        .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierAccent)
                    Button { attachments = [] } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
                }
                if webEnabled {
                    Label("Web", systemImage: "globe").font(AtelierFont.eyebrow).foregroundStyle(Color.atelierAccent)
                }
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(sendReady ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain).disabled(!sendReady)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send (⌘↩)")
            }
        }
        .padding(12)
        .overlay(alignment: .top) { Divider().background(Color.atelierDivider).opacity(0.6) }
    }

    private var sendReady: Bool {
        !liveRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedRoom != nil
    }

    // MARK: Context + brief rail

    private var contextAndBriefRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                contextSection
                Divider().background(Color.atelierDivider).opacity(0.6)
                briefSection
            }
            .padding(16)
        }
        .background(Color.atelierSurface.opacity(0.3))
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTEXT").font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierInk)

            // Pinned folders (Read/Glob/Grep access).
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel("FOLDERS")
                    Spacer()
                    Button { pinFolder() } label: { Image(systemName: "plus.circle").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(Color.atelierAccent)
                        .help("Pin a folder Claude can read (Read/Glob/Grep).")
                }
                let folders = selectedRoom?.contextPaths ?? []
                if folders.isEmpty {
                    Text("None — pin the codebase or the folders this feature touches.")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                } else {
                    ForEach(folders, id: \.self) { path in
                        pinRow(text: (path as NSString).lastPathComponent, full: path) { removeFolder(path) }
                    }
                }
            }

            // Shared files (feature flow): attachments persisted with the feature —
            // they survive the chat and get routed to tasks at decompose time.
            if featureId != nil {
                sharedFilesSection
            }

            // Pinned links (WebFetch when web is on / links present).
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("LINKS")
                let links = selectedRoom?.contextLinks ?? []
                ForEach(links, id: \.self) { link in
                    pinRow(text: link, full: link) { removeLink(link) }
                }
                HStack(spacing: 6) {
                    TextField("https://…", text: $newLink).textFieldStyle(.roundedBorder)
                    Button("Add") { addLink() }
                        .disabled(newLink.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Text(featureId == nil
                 ? "Spec docs, screenshots & files: attach them with ＋ in the composer (images are read as images, text/PDF is extracted). Pinned folders persist across passes; attachments ride along with the message you send."
                 : "Spec docs, screenshots & files: attach them with ＋ in the composer (images are read as images, text/PDF is extracted). They're kept with the feature (FILES above) and routed to the tasks that need them at decompose time.")
                .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Collapsible list of the feature's shared files, with image thumbnails. The chevron
    /// hides/reveals it; removal deletes from the feature store (already-routed task copies
    /// are unaffected).
    private var sharedFilesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { sharedFilesCollapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(sharedFilesCollapsed ? 0 : 90))
                        SectionLabel("FILES")
                        if !sharedFiles.isEmpty {
                            Text("\(sharedFiles.count)")
                                .font(AtelierFont.eyebrow)
                                .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                        }
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
                .help("Files shared with this feature — sent to the decomposer and routed to the tasks that need them.")
                Spacer()
            }
            if let note = sharedFilesNote {
                Text(note).font(AtelierFont.caption).foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sharedFilesCollapsed {
                if sharedFiles.isEmpty {
                    Text("None — attach files with ＋ in the composer; they're kept with the feature.")
                        .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary)
                } else {
                    ForEach(sharedFiles, id: \.self) { url in
                        sharedFileRow(url)
                    }
                }
            }
        }
    }

    private func sharedFileRow(_ url: URL) -> some View {
        HStack(spacing: 6) {
            SharedFileThumb(url: url)
            Text(url.lastPathComponent)
                .font(AtelierFont.captionMono).foregroundStyle(Color.atelierInk)
                .lineLimit(1).truncationMode(.middle).help(url.path)
            Spacer(minLength: 4)
            Button {
                FeatureAttachments.remove(fileURL: url)
                reloadSharedFiles()
            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reloadSharedFiles() {
        guard let featureId else { sharedFiles = []; return }
        sharedFiles = FeatureAttachments.list(projectRoot: project.path, featureId: featureId)
    }

    private func pinRow(text: String, full: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "smallcircle.filled.circle").font(.system(size: 7)).foregroundStyle(Color.atelierAccent)
            Text(text).font(AtelierFont.captionMono).foregroundStyle(Color.atelierInk)
                .lineLimit(1).truncationMode(.middle).help(full)
            Spacer(minLength: 4)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BRIEF").font(AtelierFont.eyebrow.weight(.semibold)).foregroundStyle(Color.atelierInk)
                Spacer()
                if refining {
                    Button(action: requestStopRefining) {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Stop").font(AtelierFont.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.atelierInkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop refining after the current pass.")
                } else {
                    Button(action: startRefinement) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.system(size: 10))
                            Text(refineConverged ? "Refine again" : "Refine").font(AtelierFont.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.atelierAccent)
                    }
                    .buttonStyle(.plain).disabled(liveRunning || selectedRoom == nil)
                    .help("Critique and rewrite the brief over multiple passes until it stabilises (testable acceptance, strict TDD\(profile.build.coverageTarget.map { ", ≥\($0)% coverage aim" } ?? "")).")
                }
            }
            if !refineStatus.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: refineConverged ? "checkmark.seal.fill" : (refining ? "arrow.triangle.2.circlepath" : "info.circle"))
                        .font(.system(size: 9))
                        .foregroundStyle(refineConverged ? Palette.success : Color.atelierInkSecondary)
                    Text(refineStatus).font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                }
            }
            if embedded {
                briefFilePreview
            } else {
                Text("Edit freely. This is what gets sent to Fill kanban.")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                TextEditor(text: $briefEditing)
                    .scrollContentBackground(.hidden)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 200, maxHeight: 360)
                    .padding(8)
                    .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider, lineWidth: 1))
                Button(action: sendToKanban) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                        Text("Send to Fill kanban").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(briefReady ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                }
                .buttonStyle(.plain).disabled(!briefReady)
                .help("Open Fill kanban pre-filled with this brief, ready to decompose into tasks.")
            }
        }
    }

    /// Live, read-only preview of `brief.md` — Claude keeps it up to date as you chat (no copy-paste).
    private var briefFilePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("brief.md — Claude keeps this up to date as you chat")
                    .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Menu {
                    Button("Open in default editor") { openBriefFile(with: nil) }
                    let editors = detectedEditors
                    if !editors.isEmpty {
                        Divider()
                        ForEach(editors, id: \.self) { ed in
                            Button("Open in \(ed.name)") { openBriefFile(with: ed.url) }
                        }
                    }
                    Divider()
                    Button("Reveal in Finder") { revealBriefFile() }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Color.atelierInkSecondary)
                .help("Open brief.md in your editor")
                Button { briefPreviewCollapsed.toggle() } label: {
                    Image(systemName: briefPreviewCollapsed ? "chevron.down" : "chevron.up").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(Color.atelierInkSecondary)
                .help(briefPreviewCollapsed ? "Show the brief" : "Hide the brief")
            }
            if !briefPreviewCollapsed {
                ScrollView {
                    if briefFileContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("The brief will appear here as you describe the feature — Claude writes and refines brief.md for you.")
                            .font(AtelierFont.caption).foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } else {
                        MarkdownView(source: briefFileContent)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                .frame(minHeight: 220, maxHeight: 400)
                .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider, lineWidth: 1))
            }
        }
    }

    private var briefReady: Bool {
        embedded ? !briefFileContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 : !briefEditing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func ensureBrief() {
        // Embedded (feature flow): bind to the one pinned brief, no picker; the brief is a live file.
        if let pinned = pinnedBriefId {
            if selectedBriefId != pinned, let room = store.chatRoom(id: pinned) { selectBrief(room) }
            ensureBriefFile()
            loadBriefFile()
            return
        }
        if let id = selectedBriefId, store.chatRoom(id: id) != nil { return }
        if let first = store.briefRooms(in: project.id).first {
            selectBrief(first)
        } else {
            createBrief()
        }
    }

    private func createBrief() {
        Task {
            if let room = try? await store.createBriefRoom(projectId: project.id, model: profile.defaultModel) {
                await MainActor.run { selectBrief(room) }
            }
        }
    }

    private func selectBrief(_ room: ChatRoom) {
        persistBrief()   // save edits to the outgoing brief before switching
        selectedBriefId = room.id
        briefEditing = room.briefText ?? ""
        attachments = []
        resetRefineState()
        // Load prior conversation from disk if there's no live turn for this room.
        historyMessages = []
        if chatSpawner.turn(for: room.id) == nil, let sid = room.sessionId {
            historyMessages = ChatJSONLReader.messages(cwd: room.scratchPath, sessionId: sid)
        }
    }

    private func send() {
        guard let room = selectedRoom else { return }
        let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        // New info supersedes a prior convergence — clear the stale "stable" note.
        if refineConverged || !refineStatus.isEmpty { refineConverged = false; refineStatus = "" }
        let firstTurn = (room.sessionId == nil) && messages.isEmpty
        let text = firstTurn ? framingPreamble(room) + "\n\nMy request:\n" + msg : msg
        let pins = room.contextPaths
        chatSpawner.send(room: room,
                         message: text,
                         store: store,
                         attachments: attachments,
                         allowWeb: webEnabled || !room.contextLinks.isEmpty,
                         allowFileEdit: embedded,   // embedded: Claude maintains brief.md live
                         contextPath: pins.first,
                         extraDirs: Array(pins.dropFirst()))
        // Feature flow: attachments don't just ride along with this message — persist them in
        // the feature store so they survive the chat and get routed to tasks at decompose time.
        // Copies run OFF the main thread; failures are SURFACED (never silently dropped: the
        // UI promises these files are "kept with the feature").
        if let featureId {
            let toStore = attachments
            let projectPath = project.path
            Task { @MainActor in
                let failures: [String] = await Task.detached(priority: .userInitiated) {
                    var out: [String] = []
                    for url in toStore {
                        do { _ = try FeatureAttachments.store(sourceURL: url, featureId: featureId,
                                                              projectRoot: projectPath) }
                        catch { out.append(url.lastPathComponent) }
                    }
                    return out
                }.value
                reloadSharedFiles()
                sharedFilesNote = failures.isEmpty ? nil
                    : "Couldn't keep \(failures.joined(separator: ", ")) with the feature — the message still carried \(failures.count == 1 ? "it" : "them"), but decompose won't be able to route \(failures.count == 1 ? "it" : "them") to tasks. Re-attach to retry."
            }
        }
        draft = ""
        attachments = []
    }

    // MARK: Living brief file (embedded feature flow)

    private func ensureBriefFile() {
        guard let room = selectedRoom else { return }
        // The scratch dir is the worker's cwd — make sure it exists so `brief.md` + Reveal work.
        try? FileManager.default.createDirectory(atPath: room.scratchPath, withIntermediateDirectories: true)
    }

    private func loadBriefFile() {
        guard let room = selectedRoom else { briefFileContent = ""; return }
        briefFileContent = (try? String(contentsOf: room.briefFileURL, encoding: .utf8)) ?? ""
    }

    private func revealBriefFile() {
        guard let room = selectedRoom else { return }
        let url = room.briefFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: room.scratchPath)])
        }
    }

    /// A text editor installed on this Mac, offered in the "Open in…" menu.
    private struct EditorApp: Hashable { let name: String; let url: URL }

    /// Common code editors detected via LaunchServices (by bundle id). Only computed when the
    /// "Open in…" menu is opened (Menu content is lazy), so no per-render cost.
    private var detectedEditors: [EditorApp] {
        let known: [(name: String, bundleId: String)] = [
            ("Sublime Text", "com.sublimetext.4"),
            ("Sublime Text", "com.sublimetext.3"),
            ("Visual Studio Code", "com.microsoft.VSCode"),
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("Zed", "dev.zed.Zed"),
            ("Nova", "com.panic.Nova"),
            ("BBEdit", "com.barebones.bbedit"),
            ("TextMate", "com.macromates.TextMate"),
        ]
        var out: [EditorApp] = []
        var seenNames = Set<String>()
        for e in known where !seenNames.contains(e.name) {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundleId) {
                out.append(EditorApp(name: e.name, url: u)); seenNames.insert(e.name)
            }
        }
        return out
    }

    /// Opens brief.md in a specific editor, or the user's default `.md` handler when `appURL` is nil.
    private func openBriefFile(with appURL: URL?) {
        guard let room = selectedRoom else { return }
        ensureBriefFile()
        let url = room.briefFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)   // create so the editor has a file
        }
        if let appURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Refinement loop (étape 2 — converge to a stable brief)

    /// Kicks off a multi-pass refinement. Each pass critiques the current brief (open questions,
    /// gaps, untestable criteria), resolves them by stating reasonable assumptions, and rewrites —
    /// converging on its own. The user can Stop, or run it again afterwards.
    private func startRefinement() {
        guard selectedRoom != nil, !liveRunning, !refining else { return }
        refining = true
        refineStop = false
        refineConverged = false
        refinePass = 0
        refinePrevBrief = (embedded ? briefFileContent : briefEditing).trimmingCharacters(in: .whitespacesAndNewlines)
        sendRefinePass()
    }

    private func requestStopRefining() { refineStop = true }

    private func resetRefineState() {
        refining = false
        refineStop = false
        refineConverged = false
        refinePass = 0
        refineStatus = ""
        refinePrevBrief = ""
    }

    private func sendRefinePass() {
        guard let room = selectedRoom else { finishRefining(note: ""); return }
        refinePass += 1
        refineStatus = "Refining · pass \(refinePass)/\(maxRefinePasses)…"
        let pins = room.contextPaths
        chatSpawner.send(room: room,
                         message: refinePrompt(current: embedded ? briefFileContent : briefEditing),
                         store: store,
                         allowWeb: false,
                         allowFileEdit: embedded,
                         contextPath: pins.first,
                         extraDirs: Array(pins.dropFirst()))
    }

    /// Called when a refine pass completes: load the rewritten brief, judge convergence, then loop
    /// (next pass) or stop (stable / cap / user stop).
    private func handleRefinePassFinished() {
        guard let last = liveTurn?.messages.last, last.role == .assistant else {
            finishRefining(note: "Refinement stopped — no reply.")
            return
        }
        let (parsed, signal) = RefineSignal.parse(last.text)
        // Embedded: brief.md is the source of truth (already reloaded this turn); the chat reply
        // carries only the convergence trailer. Standalone: the reply carries the rewritten brief.
        let brief: String
        if embedded {
            brief = briefFileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            if !parsed.isEmpty { briefEditing = parsed; persistBrief() }
            brief = parsed.isEmpty ? briefEditing.trimmingCharacters(in: .whitespacesAndNewlines) : parsed
        }
        let similarity = RefineSignal.similarity(refinePrevBrief, brief)
        let noOpenQuestions = signal.openQuestions.isEmpty
        let noMaterialChange = !signal.materiallyChanged || similarity >= 0.92
        let stable = signal.stable || (noOpenQuestions && noMaterialChange)

        if refineStop {
            finishRefining(note: "Stopped at pass \(refinePass).")
        } else if stable {
            refineConverged = true
            finishRefining(note: "Stable after \(refinePass) pass\(refinePass == 1 ? "" : "es").")
        } else if refinePass >= maxRefinePasses {
            let open = noOpenQuestions ? "" : " · \(signal.openQuestions.count) open question\(signal.openQuestions.count == 1 ? "" : "s") left"
            finishRefining(note: "Reached the \(maxRefinePasses)-pass cap\(open).")
        } else {
            refinePrevBrief = brief
            sendRefinePass()
        }
    }

    private func finishRefining(note: String) {
        refining = false
        refineStatus = note
    }

    /// One refinement pass: critique → resolve-by-assumption → rewrite, then a machine trailer that
    /// drives convergence. The current (possibly hand-edited) brief is fed back in so manual edits
    /// are respected.
    private func refinePrompt(current: String) -> String {
        if embedded { return embeddedRefinePrompt() }
        let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverage = profile.build.coverageTarget.map { " and a coverage AIM of ≥ \($0)%" } ?? ""
        let currentBlock = cur.isEmpty
            ? "There is no distilled brief yet — produce the first consolidated version from the original request and everything discussed above."
            : "Current distilled brief to critique and improve:\n\"\"\"\n\(cur)\n\"\"\""
        return """
        Refinement pass. Re-ground on the ORIGINAL request and ALL context above, then improve the brief.

        \(currentBlock)

        Do, in order:
        1. CRITIQUE: find the open questions, gaps, ambiguities, and any acceptance criteria that aren't objectively testable.
        2. RESOLVE: answer each by making the most reasonable assumption given the original request and the pinned context — and STATE those assumptions explicitly in Context/Constraints. Keep an item as an OPEN QUESTION only if it genuinely needs the human and would change the implementation.
        3. REWRITE the single consolidated brief as clean markdown (no fences) with these sections, dropping none:
        ## Goal — one sentence outcome.
        ## Context — self-contained background + the assumptions you made this pass.
        ## Constraints — hard requirements, non-goals, what not to touch.
        ## Acceptance criteria — objectively TESTABLE bullets. Strict TDD: each must be verifiable by a test written first that then passes\(coverage).
        ## Open questions — genuinely-blocking questions for the human, or "None".

        Then, on a NEW LINE after the brief, output EXACTLY this trailer (no fences, nothing after it):
        \(RefineSignal.sentinel)
        {"open_questions": ["..."], "materially_changed": true|false, "stable": true|false}
        materially_changed = did this rewrite change the brief in a way that matters vs the version above; stable = no open questions remain AND another pass would not materially change it.
        """
    }

    private func sendToKanban() {
        let text = briefEditing.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = messages.last(where: { $0.role == .assistant })?.text ?? ""
        let final = text.isEmpty ? fallback : text
        guard !final.isEmpty else { return }
        persistBrief()
        let inspect = !(selectedRoom?.contextPaths.isEmpty ?? true)
        onSendToFillKanban(final, [], inspect)
    }

    /// Embedded (feature flow): the brief lives in `brief.md`, which Claude reads + edits every turn.
    private func embeddedRefinePrompt() -> String {
        let coverage = profile.build.coverageTarget.map { " and a coverage AIM of ≥ \($0)%" } ?? ""
        return """
        Refinement pass on `brief.md` (in your working directory). Re-ground on the original request and ALL context above.
        1. CRITIQUE brief.md: open questions, gaps, ambiguities, and any acceptance criteria that aren't objectively testable.
        2. RESOLVE by making the most reasonable assumption given the context — STATE those assumptions in Context/Constraints. Keep an item under ## Open questions only if it genuinely needs the human.
        3. REWRITE `brief.md` accordingly, keeping the sections: ## Goal, ## Context, ## Constraints, ## Acceptance criteria (objectively TESTABLE — strict TDD, tests first that then pass\(coverage)), ## Open questions.
        Then reply IN CHAT with ONLY this trailer (no brief text, nothing else):
        \(RefineSignal.sentinel)
        {"open_questions": ["..."], "materially_changed": true|false, "stable": true|false}
        materially_changed = did this rewrite change brief.md in a way that matters; stable = no open questions remain AND another pass wouldn't materially change it.
        """
    }

    private func framingPreamble(_ room: ChatRoom) -> String {
        if embedded { return embeddedFramingPreamble(room) }
        let coverageClause = profile.build.coverageTarget.map { ", aiming for ≥ \($0)% test coverage" } ?? ""
        var lines = [
            "You are co-authoring a precise implementation brief for a feature in this project, to be handed to a task decomposer.",
            "Interrogate me and the provided context. Ask clarifying questions. Maintain a single distilled brief covering: goal, context, constraints, and TESTABLE acceptance criteria.",
            "This project uses strict TDD — acceptance criteria must require writing tests first and them passing\(coverageClause). I will iteratively REFINE this brief over several passes until it stabilises: on each refine pass you critique the current brief, resolve ambiguities by stating reasonable assumptions, and rewrite it as clean markdown."
        ]
        if let hint = profile.build.testScaffoldingHint { lines.append("Test conventions: \(hint)") }
        if !room.contextPaths.isEmpty {
            lines.append("You have read access to these pinned folders: " + room.contextPaths.joined(separator: ", ") + ".")
        }
        if !room.contextLinks.isEmpty {
            lines.append("Fetch and incorporate these links:\n" + room.contextLinks.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// Feature-flow framing: the brief is the FILE `brief.md`, maintained live by Claude — no copy-paste.
    private func embeddedFramingPreamble(_ room: ChatRoom) -> String {
        let coverageClause = profile.build.coverageTarget.map { ", aiming for ≥ \($0)% test coverage" } ?? ""
        var lines = [
            "We are co-authoring the implementation brief for a feature. The brief lives in the file `brief.md` in your current working directory — it is the single source of truth (create it if it doesn't exist yet).",
            "On EVERY message from me: (1) read `brief.md`, (2) update it to reflect our evolving understanding, then (3) reply briefly IN CHAT with just what you changed and any open questions — do NOT paste the brief in chat.",
            "Keep `brief.md` structured with: ## Goal, ## Context, ## Constraints, ## Acceptance criteria, ## Open questions. Acceptance criteria must be objectively TESTABLE — strict TDD, tests written first that then pass\(coverageClause). Resolve ambiguities by making reasonable assumptions and stating them in Context/Constraints; keep only genuinely-blocking items under Open questions.",
            "SCOPE — you ONLY author `brief.md`. Do NOT implement the feature, write source code, add dependencies, run build/test commands, or narrate implementation steps or 'pieces'. If I paste a full feature spec, DISTILL it into the brief (Context / Constraints / Acceptance criteria) — never build it. A task decomposer and separate build workers implement it later, elsewhere. When the brief is complete (all sections filled, no blocking open questions), reply exactly 'Brief ready.' and STOP — do not continue working."
        ]
        if let hint = profile.build.testScaffoldingHint { lines.append("Test conventions: \(hint)") }
        if !room.contextPaths.isEmpty {
            lines.append("You also have read access to these pinned folders (inspect them as needed): " + room.contextPaths.joined(separator: ", ") + ".")
        }
        if !room.contextLinks.isEmpty {
            lines.append("Fetch and incorporate these links:\n" + room.contextLinks.map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Pins / persistence

    private func pinFolder() {
        guard var room = selectedRoom else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Pin a folder for Claude to read"
        if panel.runModal() == .OK {
            for url in panel.urls where !room.contextPaths.contains(url.path) {
                room.contextPaths.append(url.path)
            }
            saveRoom(room)
        }
    }

    private func removeFolder(_ path: String) {
        guard var room = selectedRoom else { return }
        room.contextPaths.removeAll { $0 == path }
        saveRoom(room)
    }

    private func addLink() {
        guard var room = selectedRoom else { return }
        let link = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !room.contextLinks.contains(link) else { return }
        room.contextLinks.append(link)
        newLink = ""
        saveRoom(room)
    }

    private func removeLink(_ link: String) {
        guard var room = selectedRoom else { return }
        room.contextLinks.removeAll { $0 == link }
        saveRoom(room)
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach to your next message"
        if panel.runModal() == .OK {
            for url in panel.urls where !attachments.contains(where: { $0.path == url.path }) {
                attachments.append(url)
            }
        }
    }

    private func persistBrief() {
        // Embedded: the brief lives in brief.md (edited by Claude), not in briefText — nothing to save.
        guard !embedded else { return }
        guard var room = selectedRoom, room.briefText != briefEditing else { return }
        room.briefText = briefEditing
        saveRoom(room)
    }

    private func saveRoom(_ room: ChatRoom) {
        Task { try? await store.updateChatRoom(room) }
    }
}

/// The standalone sheet fixes a roomy frame; embedded in the feature flow the view should size to
/// its container instead. Applies the sheet frame only when NOT embedded.
private struct EmbeddableFrame: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content.frame(minWidth: 860, idealWidth: 1000, maxWidth: 1300,
                          minHeight: 580, idealHeight: 740, maxHeight: 1000)
        }
    }
}

/// Parses a refinement pass reply into the consolidated brief (everything before the trailer) and
/// the machine convergence signal the model appends. Tolerant by design: a missing or garbled
/// trailer yields a "not stable" signal so the loop keeps going (bounded by the pass cap) rather
/// than declaring a false convergence.
private struct RefineSignal {
    var openQuestions: [String] = []
    var materiallyChanged: Bool = true
    var stable: Bool = false

    static let sentinel = "<<<ATELIER-CONVERGENCE>>>"

    static func parse(_ raw: String) -> (brief: String, signal: RefineSignal) {
        guard let range = raw.range(of: sentinel) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), RefineSignal())
        }
        let brief = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(raw[range.upperBound...])
        var signal = RefineSignal()
        if let lo = after.firstIndex(of: "{"), let hi = after.lastIndex(of: "}"), lo < hi,
           let data = String(after[lo...hi]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            signal.openQuestions = ((obj["open_questions"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
            signal.materiallyChanged = (obj["materially_changed"] as? Bool) ?? true
            signal.stable = (obj["stable"] as? Bool) ?? false
        }
        return (brief, signal)
    }

    /// Jaccard similarity over trimmed, non-empty lines — a cheap, objective "did the brief barely
    /// change?" backstop, independent of the model's own `materially_changed` self-report.
    static func similarity(_ a: String, _ b: String) -> Double {
        func lineSet(_ s: String) -> Set<String> {
            Set(s.lowercased().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        let sa = lineSet(a), sb = lineSet(b)
        if sa.isEmpty && sb.isEmpty { return 1 }
        let union = sa.union(sb).count
        return union == 0 ? 1 : Double(sa.intersection(sb).count) / Double(union)
    }
}

/// Small async-loaded thumbnail for a shared file: cached image preview (ImageThumbnailer)
/// when the file is an image, else the shared attachment icon taxonomy. The nonisolated
/// loader inherits `.task`'s cancellation — a removed/collapsed row stops decoding.
private struct SharedFileThumb: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.atelierDivider, lineWidth: 0.5))
            } else {
                Image(systemName: AttachmentService.iconSymbol(for: contentType))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 26, height: 26)
            }
        }
        .task(id: url) {
            guard contentType?.conforms(to: .image) ?? false else { thumb = nil; return }
            thumb = await ImageThumbnailer.thumbnail(at: url)
        }
    }

    private var contentType: UTType? { AttachmentService.contentType(forFilename: url.lastPathComponent) }
}
