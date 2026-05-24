// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Owns the per-room conversation state in memory for the lifetime of the
/// app session. Each `LiveChatTurn` persists across messages so events
/// accumulate (no need to round-trip through claude's persisted JSONL
/// while we're live).
///
/// Chats run via `WorkerRunner.runChat` — pure conversation mode, all
/// standard tools disallowed, no approval socket / hook. Cheap and
/// matches what a casual user expects when they think "chat".
@MainActor
@Observable
final class ChatSpawner {
    private(set) var live: [String: LiveChatTurn] = [:]
    private let logger = Logger(subsystem: "app.atelier", category: "chat-spawner")

    func turn(for roomId: String) -> LiveChatTurn? { live[roomId] }

    func isBusy(roomId: String) -> Bool {
        guard let t = live[roomId] else { return false }
        return t.isRunning
    }

    func cancel(roomId: String) {
        guard let t = live[roomId] else { return }
        t.workerTask?.cancel()
        t.isRunning = false
    }

    func send(room: ChatRoom,
              message: String,
              store: AppStore,
              attachments: [URL] = [],
              allowWeb: Bool = false,
              contextPath: String? = nil) {
        guard !isBusy(roomId: room.id) else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Reuse the existing turn so events accumulate across messages in
        // the same app run. Create one only on the first send.
        let turn = live[room.id] ?? LiveChatTurn(roomId: room.id)
        if live[room.id] == nil {
            live[room.id] = turn
        }
        turn.isRunning = true
        turn.lastErrorMessage = nil
        turn.appendUserMessage(trimmed)

        turn.workerTask = Task { @MainActor in
            await self.execute(room: room,
                               message: trimmed,
                               turn: turn,
                               store: store,
                               attachments: attachments,
                               allowWeb: allowWeb,
                               contextPath: contextPath)
        }
    }

    private func execute(room: ChatRoom,
                         message: String,
                         turn: LiveChatTurn,
                         store: AppStore,
                         attachments: [URL] = [],
                         allowWeb: Bool = false,
                         contextPath: String? = nil) async {
        // Ensure the scratch dir exists (user may have nuked it).
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: room.scratchPath, isDirectory: &isDir) || !isDir.boolValue {
            do {
                try FileManager.default.createDirectory(atPath: room.scratchPath,
                                                        withIntermediateDirectories: true)
            } catch {
                turn.lastErrorMessage = "Could not create chat scratch dir: \(error.localizedDescription)"
                turn.isRunning = false
                return
            }
        }

        // Decode attachments off the main actor (image downscale is heavy).
        let urls = attachments
        let att = await Task.detached { AIAssistant.buildAttachmentContext(urls) }.value

        var promptText = message
        if !att.text.isEmpty || !att.images.isEmpty || !att.skipped.isEmpty {
            promptText += "\n\n---\nAttached by the user"
            if !att.images.isEmpty { promptText += " (\(att.images.count) image(s) attached to this message)" }
            promptText += ":\n"
            if !att.text.isEmpty { promptText += att.text + "\n" }
            if !att.skipped.isEmpty { promptText += "Could not read: \(att.skipped.joined(separator: "; ")).\n" }
        }
        // Images can only reach the model via stream-json input.
        let imageEvent = att.images.isEmpty
            ? nil
            : AIAssistant.streamJSONUserEvent(text: promptText, images: att.images)

        let toolsOn = allowWeb || (contextPath != nil)
        let agentId = UUID()
        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: promptText,
            model: room.model,
            apiKey: APIKeyResolver.resolve(),
            agentId: agentId,
            settingsPath: "",   // unused in chat mode
            workingDirectory: room.scratchPath,
            additionalDirs: contextPath.map { [$0] } ?? [],
            includePartialMessages: false,
            maxTurns: toolsOn ? 16 : 1,
            resumeSessionId: room.sessionId,
            chatAllowWeb: allowWeb,
            chatAllowFiles: contextPath != nil,
            inputStreamJSON: imageEvent
        )

        let liveTurn = turn
        let eventSink: @Sendable (StreamEvent) async -> Void = { event in
            await MainActor.run {
                liveTurn.events.append(event)
                liveTurn.absorb(event)
            }
        }
        let stderrSink: @Sendable (String) async -> Void = { _ in }

        do {
            try await runner.runChat(invocation: invocation,
                                     onEvent: eventSink,
                                     onStderr: stderrSink)
        } catch {
            if !Task.isCancelled {
                turn.lastErrorMessage = error.localizedDescription
            }
        }

        // Persist cumulative totals back into the room.
        var updated = room
        if updated.sessionId == nil, let sid = liveTurn.sessionId {
            updated.sessionId = sid
        }
        if updated.title == "Untitled chat" {
            let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
            updated.title = String(firstLine.prefix(60))
        }
        updated.costUsd = liveTurn.totalCostUsd
        updated.inputTokens = liveTurn.inputTokens
        updated.outputTokens = liveTurn.outputTokens
        updated.cacheReadTokens = liveTurn.cacheReadTokens
        updated.cacheCreationTokens = liveTurn.cacheCreationTokens
        updated.updatedAt = Date()
        try? await store.updateChatRoom(updated)

        turn.isRunning = false
    }
}

/// In-memory conversation state for one room. Persists across messages in
/// the same app run; rebuilt from disk via SessionReader on relaunch.
///
/// We maintain two parallel views:
///   - `messages` — the user-facing bubbles (user prompts + assistant text).
///   - `events`   — the raw stream-json events from claude (system / result
///     / rate_limit / etc.). Used by the Detail toggle in the UI.
@MainActor
@Observable
final class LiveChatTurn {
    let roomId: String
    var events: [StreamEvent] = []
    var messages: [ChatMessage] = []
    var isRunning: Bool = false
    var lastErrorMessage: String?
    var sessionId: String?
    var totalCostUsd: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var workerTask: Task<Void, Never>?

    init(roomId: String) {
        self.roomId = roomId
    }

    /// Synthesised "user message" inserted when the operator hits Send —
    /// claude doesn't emit one for the argv-passed prompt, so the bubble
    /// view would otherwise look one-sided.
    func appendUserMessage(_ text: String) {
        messages.append(ChatMessage(role: .user, text: text, at: Date()))
    }

    /// Mirrors AgentState.ingest's effect on the cumulative tallies — chat
    /// doesn't reuse AgentState because its UI is simpler (no kanban status
    /// machine, no approval queue).
    func absorb(_ event: StreamEvent) {
        switch event.kind {
        case .system(_, let sid, _):
            if sessionId == nil, let s = sid { sessionId = s }
        case .assistant(let text, _, _):
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: t, at: event.timestamp))
            }
        case .result(_, let cost, let usage, _):
            if let c = cost { totalCostUsd += c }
            if let u = usage {
                inputTokens += u.inputTokens
                outputTokens += u.outputTokens
                cacheReadTokens += u.cacheReadTokens
                cacheCreationTokens += u.cacheCreationTokens
            }
        default:
            break
        }
    }
}

/// Bubble-level message rendered by the Chat view's default ("compact") mode.
struct ChatMessage: Identifiable, Hashable {
    let id: UUID = UUID()
    let role: Role
    let text: String
    let timestamp: Date

    enum Role: Hashable {
        case user
        case assistant
    }

    init(role: Role, text: String, at timestamp: Date) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
