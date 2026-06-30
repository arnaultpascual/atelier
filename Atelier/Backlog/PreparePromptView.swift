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
    /// (briefText, attachments, inspectRepo) → seeds the Fill Kanban compose screen.
    let onSendToFillKanban: (String, [URL], Bool) -> Void
    let onClose: () -> Void

    @State private var selectedBriefId: String?
    @State private var draft: String = ""
    @State private var briefEditing: String = ""
    @State private var attachments: [URL] = []
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
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            HStack(spacing: 0) {
                conversationPane
                Divider().background(Color.atelierDivider).opacity(0.6)
                contextAndBriefRail.frame(width: 330)
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, maxWidth: 1300,
               minHeight: 580, idealHeight: 740, maxHeight: 1000)
        .background(Color.atelierBackground)
        .onAppear { ensureBrief() }
        .onDisappear { persistBrief() }   // keep manual brief edits on close
        .onChange(of: liveRunning) { _, running in
            // A refinement pass just finished — capture the brief, judge convergence, loop or stop.
            guard !running, refining else { return }
            handleRefinePassFinished()
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
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Claude is thinking…").font(AtelierFont.caption)
                                    .foregroundStyle(Color.atelierInkSecondary)
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

            Text("Spec docs, screenshots & files: attach them with ＋ in the composer (images are read as images, text/PDF is extracted). Pinned folders persist across passes; attachments ride along with the message you send.")
                .font(AtelierFont.eyebrow).foregroundStyle(Color.atelierInkSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private var briefReady: Bool {
        !briefEditing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func ensureBrief() {
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
                         contextPath: pins.first,
                         extraDirs: Array(pins.dropFirst()))
        draft = ""
        attachments = []
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
        refinePrevBrief = briefEditing.trimmingCharacters(in: .whitespacesAndNewlines)
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
                         message: refinePrompt(current: briefEditing),
                         store: store,
                         allowWeb: false,
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
        // A pass that returned only the trailer (no brief) must NOT clobber the editor or seed the
        // convergence check with an empty string — fall back to the current brief for both.
        if !parsed.isEmpty {
            briefEditing = parsed
            persistBrief()
        }
        let brief = parsed.isEmpty ? briefEditing.trimmingCharacters(in: .whitespacesAndNewlines) : parsed
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

    private func framingPreamble(_ room: ChatRoom) -> String {
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
        guard var room = selectedRoom, room.briefText != briefEditing else { return }
        room.briefText = briefEditing
        saveRoom(room)
    }

    private func saveRoom(_ room: ChatRoom) {
        Task { try? await store.updateChatRoom(room) }
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
