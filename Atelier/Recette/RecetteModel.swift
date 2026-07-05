// SPDX-License-Identifier: MIT
import Foundation

/// One check in a feature's acceptance test plan (the "recette"). Codable because it is
/// ALSO the JSON schema the enrichment worker emits — the agent produces these items, the
/// app renders them into the vetted HTML template (it never authors HTML/CSS).
struct RecetteItem: Codable, Sendable, Hashable, Identifiable {
    enum Priority: String, Codable, Sendable, CaseIterable {
        case p0, p1, p2
        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var label: String { rawValue.uppercased() }
    }

    /// Stable id (used as the localStorage key for the checkbox in the rendered page).
    var id: String
    /// Section the item is rendered under (e.g. "Critères d'acceptation").
    var group: String
    var title: String
    var priority: Priority
    /// What this check validates (feature aspect / criterion / task) — the small caption.
    var validates: String
    /// Concrete manual steps. Deterministic seeds carry a generic step; the agent fleshes them out.
    var steps: [String]
    /// The pass condition.
    var expected: String
    /// Optional aside (repro tip, where to look).
    var hint: String?
}
