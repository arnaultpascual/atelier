// SPDX-License-Identifier: MIT
import Foundation

/// A finished autopilot run, persisted so it survives app restarts and can be
/// surfaced as a single grouped entity in the Done column (the integration branch
/// + all its tasks + combined diff + iterate/merge actions).
///
/// Stored as a JSON array in `<project>/.atelier/autopilot/runs.json`, newest first.
struct AutopilotRunRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String                 // == integrationBranch (unique per run)
    var projectId: String
    var integrationBranch: String
    var baseBranch: String         // what the integration branch was cut from (main/develop/…)
    var startedAt: Date
    var finishedAt: Date
    var totalCostUsd: Double
    var tasks: [TaskOutcome]

    struct TaskOutcome: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var status: Status
        var reason: String?

        enum Status: String, Codable, Sendable {
            case merged, blocked, incomplete
        }
    }

    var mergedCount: Int { tasks.filter { $0.status == .merged }.count }
    var blockedCount: Int { tasks.filter { $0.status == .blocked }.count }
}

/// Reads / writes the per-project autopilot run history. Plain JSON file, no DB —
/// it's a small human-inspectable log next to the per-task reports.
enum AutopilotRunStore {
    static func fileURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier/autopilot/runs.json")
    }

    static func load(projectPath: String) -> [AutopilotRunRecord] {
        let url = fileURL(projectPath: projectPath)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AutopilotRunRecord].self, from: data)) ?? []
    }

    /// Upserts by id (re-running / resuming the same integration branch replaces
    /// the prior record) and keeps the list newest-first.
    static func append(_ record: AutopilotRunRecord, projectPath: String) {
        var all = load(projectPath: projectPath).filter { $0.id != record.id }
        all.insert(record, at: 0)
        write(all, projectPath: projectPath)
    }

    static func remove(id: String, projectPath: String) {
        let all = load(projectPath: projectPath).filter { $0.id != id }
        write(all, projectPath: projectPath)
    }

    private static func write(_ records: [AutopilotRunRecord], projectPath: String) {
        let url = fileURL(projectPath: projectPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
