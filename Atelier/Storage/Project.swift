// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// One project = one git repository on disk. Belongs to a workspace.
struct Project: Identifiable, Hashable, Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var workspaceId: String
    var name: String
    var path: String                // absolute filesystem path
    var profileId: String?          // e.g. "nextjs-app", "swiftui-macos" — Phase 2
    var defaultModel: String?       // e.g. "claude-sonnet-4-6"
    var budgetUsdMonthly: Double?
    var autoApproveLevel: AutoApproveLevel?   // local per-project auto-approve policy (DB-only)
    /// Opt-in: run the app build before EACH task merge (+ fix loop). OFF by default — Atelier stays
    /// independent of the (often slow / env-bound / remote) app build.
    var buildVerifyBeforeMerge: Bool = false
    /// Opt-in: run ONE final app build (+ fix loop / "affinage") on the integration branch once every
    /// task is merged, during the final synthesis. Independent of `buildVerifyBeforeMerge`. OFF by default.
    var buildVerifyFinal: Bool = false
    /// Optional fast/local build target for verification; falls back to the mode's buildCommand.
    var verifyBuildCommand: String? = nil
    /// Opt-in: when the final synthesis lands below the mode's coverage aim, run one tests-first
    /// improvement round on the integration branch. OFF by default; NEVER a gate — pure polish.
    var coverageImprovementRound: Bool = false
    var createdAt: Date

    static let databaseTableName = "project"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let workspaceId = Column(CodingKeys.workspaceId)
        static let name = Column(CodingKeys.name)
        static let path = Column(CodingKeys.path)
        static let profileId = Column(CodingKeys.profileId)
        static let defaultModel = Column(CodingKeys.defaultModel)
        static let budgetUsdMonthly = Column(CodingKeys.budgetUsdMonthly)
        static let autoApproveLevel = Column(CodingKeys.autoApproveLevel)
        static let buildVerifyBeforeMerge = Column(CodingKeys.buildVerifyBeforeMerge)
        static let buildVerifyFinal = Column(CodingKeys.buildVerifyFinal)
        static let verifyBuildCommand = Column(CodingKeys.verifyBuildCommand)
        static let coverageImprovementRound = Column(CodingKeys.coverageImprovementRound)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    /// The effective build-verify command for this project under `profile`, or nil if none.
    func resolvedVerifyBuildCommand(profile: ProjectProfile) -> String? {
        let custom = verifyBuildCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return profile.build.buildCommand
    }

    static let workspace = belongsTo(Workspace.self)
}

extension Project {
    static func newDraft(
        workspaceId: String,
        name: String,
        path: String,
        defaultModel: String? = "claude-sonnet-4-6"
    ) -> Project {
        Project(
            id: UUID().uuidString,
            workspaceId: workspaceId,
            name: name,
            path: path,
            profileId: nil,
            defaultModel: defaultModel,
            budgetUsdMonthly: nil,
            autoApproveLevel: nil,
            createdAt: Date()
        )
    }
}
