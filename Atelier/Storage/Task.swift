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
    /// The feature this task belongs to (feature-first flow). nil = a loose/project-level task
    /// (e.g. created via the classic kanban). Persisted as the `feature_id` frontmatter key.
    var featureId: String? = nil
    /// Strict-TDD gate state — orthogonal to `status` (the kanban column). Persisted
    /// as a DB column + `test_state` frontmatter key. Defaults to `.unknown`.
    var testState: TestState = .unknown
    var testSummary: String? = nil  // last test-run summary (cosmetic; e.g. "12 passed / 0 failed")
    /// Test-suite INTEGRITY — a second axis, orthogonal to `testState`. `testState` answers
    /// "do the tests pass?" (exit code); `testIntegrity` answers "did the test suite itself get
    /// weaker?" (computed from the test-file diff). A green run can still be `.suspect`.
    var testIntegrity: TestIntegrity = .unevaluated
    var testChangeNote: String? = nil   // worker's declared rationale for test edits (## TEST-CHANGES)
    var createdAt: Date
    var updatedAt: Date

    /// Result of running the mode's fast test command in the worktree. Gates review
    /// and merge: `.red`/`.regressed` are hard blocks. See `TestRunner`.
    enum TestState: String, Codable, CaseIterable, Sendable, Hashable {
        case unknown        // never run (default for legacy + brand-new tasks)
        case red            // tests written but failing — HARD BLOCK on review/merge
        case green          // last run passed in the worktree (pre-review)
        case greenMerged    // re-verified green after merge into base
        case regressed      // post-merge re-run failed — surfaced as a regression
        case noTests        // mode has no test command (or task opted out) — gate is informational
        case toolchainMissing // couldn't run tests — required toolchain (SDK/JDK/wrapper) absent

        /// True when this state must block review/merge. A missing toolchain does NOT block — it's
        /// an environment problem to surface, not a code failure.
        var blocksMerge: Bool { self == .red || self == .regressed }
    }

    /// Did the test SUITE shrink/soften vs the worktree base? Computed from the test-file diff,
    /// not the exit code (so green-by-weakening is catchable). See `TestIntegrityChecker`.
    enum TestIntegrity: String, Codable, CaseIterable, Sendable, Hashable {
        case unevaluated      // never checked (default; legacy; mode without test globs)
        case intact           // no test files changed, or only additions
        case evolved          // tests changed AND judged a legitimate design shift
        case suspect          // change flagged — advisory; autopilot runs a review+repair loop,
                              // the manual flow surfaces it (it does NOT block merge on its own)
    }

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
        static let featureId = Column("featureId")
        static let testState = Column("testState")
        static let testSummary = Column("testSummary")
        static let testIntegrity = Column("testIntegrity")
        static let testChangeNote = Column("testChangeNote")
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
        featureId = row[Columns.featureId]
        if let raw: String = row[Columns.testState], let s = TestState(rawValue: raw) {
            testState = s
        } else {
            testState = .unknown
        }
        testSummary = row[Columns.testSummary]
        if let raw: String = row[Columns.testIntegrity], let i = TestIntegrity(rawValue: raw) {
            testIntegrity = i
        } else {
            testIntegrity = .unevaluated
        }
        testChangeNote = row[Columns.testChangeNote]
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
        container[Columns.featureId] = featureId
        container[Columns.testState] = testState.rawValue
        container[Columns.testSummary] = testSummary
        container[Columns.testIntegrity] = testIntegrity.rawValue
        container[Columns.testChangeNote] = testChangeNote
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
