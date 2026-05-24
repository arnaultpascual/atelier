// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// Free-form Claude conversation that doesn't belong to a project — a
/// scratchpad for quick questions and brainstorming, no worktree, no git.
///
/// Each chat owns a scratch directory under
/// `~/Library/Application Support/Atelier/chat-scratch/<id>/`. Claude is
/// spawned with that as cwd; the persisted JSONL ends up at
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` and we read it back
/// via `SessionReader`.
struct ChatRoom: Identifiable, Hashable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var model: String
    var sessionId: String?
    var scratchPath: String
    var costUsd: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "chat_room"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let title = Column(CodingKeys.title)
        static let model = Column(CodingKeys.model)
        static let sessionId = Column(CodingKeys.sessionId)
        static let scratchPath = Column(CodingKeys.scratchPath)
        static let costUsd = Column(CodingKeys.costUsd)
        static let inputTokens = Column(CodingKeys.inputTokens)
        static let outputTokens = Column(CodingKeys.outputTokens)
        static let cacheReadTokens = Column(CodingKeys.cacheReadTokens)
        static let cacheCreationTokens = Column(CodingKeys.cacheCreationTokens)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

extension ChatRoom {
    static func scratchRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Atelier")
            .appendingPathComponent("chat-scratch")
    }

    static func newDraft(model: String = "claude-sonnet-4-6") -> ChatRoom {
        let id = UUID().uuidString
        let scratch = scratchRoot().appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let now = Date()
        return ChatRoom(
            id: id,
            title: "Untitled chat",
            model: model,
            sessionId: nil,
            scratchPath: scratch.path,
            costUsd: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            createdAt: now,
            updatedAt: now
        )
    }
}
