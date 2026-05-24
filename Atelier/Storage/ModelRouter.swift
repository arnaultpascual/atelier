// SPDX-License-Identifier: MIT
import Foundation

/// Decides which Claude model to use for a given task.
///
/// Two paths:
/// - **Rules** (`suggestFromRules`) — spec §7.3, instant, deterministic, no network.
/// - **AI** (`suggestFromHaiku`) — one-shot `claude -p --model claude-haiku-4-5-...`
///   query that reads the task and returns a recommendation. Costs ~$0.0001 on the
///   API or is free under a Claude Code subscription. Takes 1-3 seconds.
///
/// At spawn time, if a task's `workerModel` is nil (Auto mode) we apply `suggestFromRules`
/// automatically. Users can also click "Suggest" in the task detail to pre-bake a model.
enum ModelRouter {
    enum Model: String, CaseIterable, Sendable {
        case opus47 = "claude-opus-4-7"
        case opus46 = "claude-opus-4-6"
        case sonnet46 = "claude-sonnet-4-6"
        case haiku45 = "claude-haiku-4-5-20251001"

        var displayName: String {
            switch self {
            case .opus47: return "Opus 4.7"
            case .opus46: return "Opus 4.6"
            case .sonnet46: return "Sonnet 4.6"
            case .haiku45: return "Haiku 4.5"
            }
        }
    }

    struct Suggestion: Sendable {
        let model: Model
        let reason: String
    }

    // MARK: - Rule-based suggestion (spec §7.3)

    static func suggestFromRules(forTask task: AtelierTask) -> Suggestion {
        let labels = Set(task.labels.map { $0.lowercased() })
        let heavyLabels: Set<String> = ["refactor", "architecture", "perf", "performance"]
        let trivialLabels: Set<String> = ["simple", "chore", "rename", "docs", "doc", "typo"]

        if !labels.isDisjoint(with: heavyLabels) {
            return .init(model: .opus47,
                         reason: "Labels suggest deep work (refactor / architecture / perf) — Opus 4.7 for depth.")
        }
        if !labels.isDisjoint(with: trivialLabels) {
            return .init(model: .haiku45,
                         reason: "Labels suggest a chore (rename / docs / simple) — Haiku 4.5 is fast and cheap.")
        }
        let descLen = task.descriptionMd?.count ?? 0
        if descLen > 1500 || task.dependsOn.count > 2 {
            return .init(model: .opus46,
                         reason: "Long description or multi-step task (\(descLen) chars, \(task.dependsOn.count) deps) — Opus 4.6 balances depth and cost.")
        }
        return .init(model: .sonnet46,
                     reason: "Standard feature work — Sonnet 4.6 covers most cases.")
    }

    /// Convenience: delegates to AIAssistant.suggestModel.
    static func suggestFromHaiku(forTask task: AtelierTask, apiKey: String?) async throws -> Suggestion {
        try await AIAssistant.suggestModel(forTask: task, apiKey: apiKey)
    }

    // MARK: - Auto resolution at spawn time

    /// Returns the model id to use for the task. If the task has an explicit
    /// `workerModel`, it wins; otherwise apply the rules from spec §7.3.
    static func resolve(task: AtelierTask, projectDefault: String?) -> String {
        if let m = task.workerModel, !m.isEmpty { return m }
        if let pd = projectDefault, !pd.isEmpty { return pd }
        return suggestFromRules(forTask: task).model.rawValue
    }
}
