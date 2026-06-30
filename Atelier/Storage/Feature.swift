// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// One *feature* = one guided build inside a Project. It is the unit the new feature-first UX walks
/// the user through, stage by stage: prerequisites → brief → tasks → build → finish. A project owns
/// many features; each feature owns its brief (a Prepare-Prompt chat room), its tasks (linked later
/// by `task.featureId`), its autopilot integration branch, and its final deliverable.
///
/// The DB row is the source of truth for a feature (unlike tasks, which mirror `backlog/*.md`).
struct Feature: Identifiable, Hashable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var name: String
    /// Furthest stage the feature has reached in the guided flow (the stepper's current step).
    var stage: Stage
    /// The Prepare-Prompt chat room backing this feature's brief (created when entering the brief stage).
    var briefRoomId: String?
    /// The autopilot run's integration branch, once the build stage has started.
    var integrationBranch: String?
    /// `FEATURE-<slug>.md` at the project root, once the finish stage produced it.
    var deliverablePath: String?
    /// Set when the feature is fully finished (deliverable produced + integration merged).
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "feature"

    /// The five guided stages, in order. `order`/`allCases` drive the stepper header.
    enum Stage: String, Codable, CaseIterable, Sendable, Hashable {
        case prerequisites      // toolchain check for the project's mode
        case brief              // co-author + refine the brief to stability
        case tasks              // decompose into a task list, edit/iterate
        case building           // kanban + autopilot builds the tasks
        case finish             // re-test/coverage/conformity + deliverables

        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// Short label for the stepper chip.
        var label: String {
            switch self {
            case .prerequisites: return "Prerequisites"
            case .brief: return "Brief"
            case .tasks: return "Tasks"
            case .building: return "Build"
            case .finish: return "Finish"
            }
        }

        var iconSystemName: String {
            switch self {
            case .prerequisites: return "checklist"
            case .brief: return "text.append"
            case .tasks: return "list.bullet.rectangle"
            case .building: return "infinity"
            case .finish: return "checkmark.seal"
            }
        }

        /// One-line description of what the stage does (shown in placeholders + the stepper).
        var summary: String {
            switch self {
            case .prerequisites: return "Confirm the mode's toolchain so the build can actually run."
            case .brief: return "Co-author and refine a testable, TDD-ready brief until it stabilises."
            case .tasks: return "Decompose the brief into a task list you can edit and iterate on."
            case .building: return "Run the autopilot: dev → test gate → review → merge, per task."
            case .finish: return "Re-test, measure coverage, check conformity, and write the deliverables."
            }
        }
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectId = Column(CodingKeys.projectId)
        static let name = Column(CodingKeys.name)
        static let stage = Column(CodingKeys.stage)
        static let briefRoomId = Column(CodingKeys.briefRoomId)
        static let integrationBranch = Column(CodingKeys.integrationBranch)
        static let deliverablePath = Column(CodingKeys.deliverablePath)
        static let completedAt = Column(CodingKeys.completedAt)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    static func newDraft(projectId: String, name: String) -> Feature {
        let now = Date()
        return Feature(id: UUID().uuidString,
                       projectId: projectId,
                       name: name,
                       stage: .prerequisites,
                       briefRoomId: nil,
                       integrationBranch: nil,
                       deliverablePath: nil,
                       completedAt: nil,
                       createdAt: now,
                       updatedAt: now)
    }

    var isCompleted: Bool { completedAt != nil }
}
