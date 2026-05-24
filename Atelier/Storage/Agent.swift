// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// Persisted agent record — one row per worker spawn (DB-backed mirror of the
/// in-memory `AgentState` we use for the live UI).
///
/// Lifecycle:
/// - `spawned` on insert
/// - `running` when the first `assistant`/`system` event arrives
/// - `awaitingApproval` while an Inbox decision is pending (Phase 1.3+)
/// - `completed` on `result.success`
/// - `failed`   on `result.error_*`, non-zero exit, or unhandled subprocess error
/// - `killed`   when the user explicitly cancels
struct Agent: Identifiable, Hashable, Sendable {
    var id: String                  // UUID string
    var taskId: String
    var worktreePath: String
    var branch: String
    var pid: Int?
    var status: Status
    var model: String
    var sessionId: String?
    var sessionJsonlPath: String?
    var costUsd: Double
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var startedAt: Date?
    var endedAt: Date?

    enum Status: String, Codable, CaseIterable, Sendable, Hashable {
        case spawned
        case running
        case awaitingApproval
        case completed
        case failed
        case killed

        var isTerminal: Bool {
            self == .completed || self == .failed || self == .killed
        }
        var displayName: String {
            switch self {
            case .spawned: return "Spawned"
            case .running: return "Running"
            case .awaitingApproval: return "Awaiting approval"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .killed: return "Killed"
            }
        }
    }
}

extension Agent {
    static func newSpawn(taskId: String,
                         worktreePath: String,
                         branch: String,
                         model: String) -> Agent {
        Agent(
            id: UUID().uuidString,
            taskId: taskId,
            worktreePath: worktreePath,
            branch: branch,
            pid: nil,
            status: .spawned,
            model: model,
            sessionId: nil,
            sessionJsonlPath: nil,
            costUsd: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            startedAt: Date(),
            endedAt: nil
        )
    }
}

// MARK: - GRDB

extension Agent: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agent"

    enum Columns {
        static let id = Column("id")
        static let taskId = Column("taskId")
        static let worktreePath = Column("worktreePath")
        static let branch = Column("branch")
        static let pid = Column("pid")
        static let status = Column("status")
        static let model = Column("model")
        static let sessionId = Column("sessionId")
        static let sessionJsonlPath = Column("sessionJsonlPath")
        static let costUsd = Column("costUsd")
        static let inputTokens = Column("inputTokens")
        static let outputTokens = Column("outputTokens")
        static let cacheReadTokens = Column("cacheReadTokens")
        static let cacheCreationTokens = Column("cacheCreationTokens")
        static let startedAt = Column("startedAt")
        static let endedAt = Column("endedAt")
    }

    init(row: Row) throws {
        id = row[Columns.id]
        taskId = row[Columns.taskId]
        worktreePath = row[Columns.worktreePath]
        branch = row[Columns.branch]
        pid = row[Columns.pid]
        let raw: String = row[Columns.status]
        status = Status(rawValue: raw) ?? .failed
        model = row[Columns.model]
        sessionId = row[Columns.sessionId]
        sessionJsonlPath = row[Columns.sessionJsonlPath]
        costUsd = row[Columns.costUsd]
        inputTokens = row[Columns.inputTokens]
        outputTokens = row[Columns.outputTokens]
        cacheReadTokens = row[Columns.cacheReadTokens]
        cacheCreationTokens = row[Columns.cacheCreationTokens]
        startedAt = row[Columns.startedAt]
        endedAt = row[Columns.endedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.taskId] = taskId
        container[Columns.worktreePath] = worktreePath
        container[Columns.branch] = branch
        container[Columns.pid] = pid
        container[Columns.status] = status.rawValue
        container[Columns.model] = model
        container[Columns.sessionId] = sessionId
        container[Columns.sessionJsonlPath] = sessionJsonlPath
        container[Columns.costUsd] = costUsd
        container[Columns.inputTokens] = inputTokens
        container[Columns.outputTokens] = outputTokens
        container[Columns.cacheReadTokens] = cacheReadTokens
        container[Columns.cacheCreationTokens] = cacheCreationTokens
        container[Columns.startedAt] = startedAt
        container[Columns.endedAt] = endedAt
    }
}
