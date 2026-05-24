// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// One task = one `backlog/tasks/<id>-<slug>.md` file inside a Project.
///
/// The .md file (frontmatter + markdown body) is the source of truth; the DB row is
/// a cache rebuildable from disk. We use custom GRDB conformances so `labels` and
/// `dependsOn` round-trip as JSON-encoded TEXT columns without ceremony at call sites.
struct AtelierTask: Identifiable, Hashable, Sendable {
    var id: String                  // e.g. "task-001"
    var projectId: String
    var title: String
    var status: Status
    var priority: Priority?
    var labels: [String]
    var mdPath: String              // relative to the project root, e.g. "backlog/tasks/task-001-foo.md"
    var dependsOn: [String]
    var workerModel: String?
    var budgetUsd: Double?
    var descriptionMd: String?      // markdown body after the frontmatter
    var attachments: [String]       // relative paths, e.g. ".atelier/attachments/task-001/foo.png"
    var createdAt: Date
    var updatedAt: Date

    enum Status: String, Codable, CaseIterable, Sendable, Hashable {
        case toDo = "To Do"
        case inProgress = "In Progress"
        case review = "Review"
        case done = "Done"
        case blocked = "Blocked"

        var displayName: String { rawValue }
        var order: Int {
            switch self {
            case .toDo: return 0
            case .inProgress: return 1
            case .review: return 2
            case .done: return 3
            case .blocked: return 4
            }
        }
        static let kanbanOrder: [Status] = [.toDo, .inProgress, .review, .done, .blocked]
    }

    enum Priority: String, Codable, CaseIterable, Sendable, Hashable {
        case low, medium, high, critical

        var displayName: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .critical: return "Critical"
            }
        }
    }

    /// Convenience accessor for the task's absolute path on disk (needs the project's root path).
    func absoluteMdPath(projectRoot: String) -> String {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(mdPath).path
    }
}

extension AtelierTask {
    static func newDraft(
        id: String,
        projectId: String,
        title: String,
        mdPath: String,
        status: Status = .toDo,
        priority: Priority? = nil,
        workerModel: String? = nil
    ) -> AtelierTask {
        let now = Date()
        return AtelierTask(
            id: id,
            projectId: projectId,
            title: title,
            status: status,
            priority: priority,
            labels: [],
            mdPath: mdPath,
            dependsOn: [],
            workerModel: workerModel,
            budgetUsd: nil,
            descriptionMd: nil,
            attachments: [],
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - GRDB

extension AtelierTask: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "task"

    enum Columns {
        static let id = Column("id")
        static let projectId = Column("projectId")
        static let title = Column("title")
        static let status = Column("status")
        static let priority = Column("priority")
        static let labels = Column("labels")
        static let mdPath = Column("mdPath")
        static let dependsOn = Column("dependsOn")
        static let workerModel = Column("workerModel")
        static let budgetUsd = Column("budgetUsd")
        static let descriptionMd = Column("descriptionMd")
        static let attachments = Column("attachments")
        static let createdAt = Column("createdAt")
        static let updatedAt = Column("updatedAt")
    }

    init(row: Row) throws {
        id = row[Columns.id]
        projectId = row[Columns.projectId]
        title = row[Columns.title]
        if let raw: String = row[Columns.status], let s = Status(rawValue: raw) {
            status = s
        } else {
            status = .toDo
        }
        if let raw: String? = row[Columns.priority], let raw, let p = Priority(rawValue: raw) {
            priority = p
        } else {
            priority = nil
        }
        labels = Self.decodeStringArray(row[Columns.labels])
        mdPath = row[Columns.mdPath]
        dependsOn = Self.decodeStringArray(row[Columns.dependsOn])
        workerModel = row[Columns.workerModel]
        budgetUsd = row[Columns.budgetUsd]
        descriptionMd = row[Columns.descriptionMd]
        attachments = Self.decodeStringArray(row[Columns.attachments])
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.projectId] = projectId
        container[Columns.title] = title
        container[Columns.status] = status.rawValue
        container[Columns.priority] = priority?.rawValue
        container[Columns.labels] = Self.encodeStringArray(labels)
        container[Columns.mdPath] = mdPath
        container[Columns.dependsOn] = Self.encodeStringArray(dependsOn)
        container[Columns.workerModel] = workerModel
        container[Columns.budgetUsd] = budgetUsd
        container[Columns.descriptionMd] = descriptionMd
        container[Columns.attachments] = Self.encodeStringArray(attachments)
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private static func encodeStringArray(_ arr: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arr),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}
