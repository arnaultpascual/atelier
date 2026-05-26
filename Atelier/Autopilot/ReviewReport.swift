// SPDX-License-Identifier: MIT
import Foundation

/// Severity of a single review finding. Only `critical`/`major` are *blocking* — the autopilot
/// auto-applies fixes for those and leaves `minor`/`cosmetic` untouched (and still merges).
enum ReviewSeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case critical, major, minor, cosmetic

    var isBlocking: Bool { self == .critical || self == .major }

    /// Lenient mapping of loose model output ("CRITICAL", "blocker", "high"…) onto a case.
    init(lenient raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "critical", "crit", "blocker", "blocking": self = .critical
        case "major", "high", "significant":            self = .major
        case "minor", "low", "medium", "med", "moderate": self = .minor
        default:                                         self = .cosmetic
        }
    }
}

enum ReviewVerdict: String, Codable, Sendable, Hashable {
    case approve, changesRequested, needsDiscussion

    init(lenient raw: String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if v.contains("APPROVE") { self = .approve }
        else if v.contains("CHANGES") { self = .changesRequested }
        else { self = .needsDiscussion }
    }
}

/// One reviewer-reported issue. `severity` drives whether the autopilot fixes it.
struct ReviewFinding: Identifiable, Sendable, Hashable {
    let id = UUID()
    let severity: ReviewSeverity
    let file: String?
    let line: Int?
    let summary: String
    let suggestedFix: String

    /// "[critical] path:line — summary" for fix prompts and the UI.
    var oneLine: String {
        let loc = [file, line.map(String.init)].compactMap { $0 }.joined(separator: ":")
        return "[\(severity.rawValue)]\(loc.isEmpty ? "" : " \(loc)") — \(summary)"
    }
}

/// Structured result of an autopilot review pass. The merge decision is purely
/// `blockingFindings.isEmpty` — the `verdict` is informational (shown in the UI). A review that
/// can't be produced or parsed makes `AIAssistant.reviewWorktree` *throw*, so the runner blocks
/// rather than ever merging an unknown review.
struct ReviewReport: Sendable {
    let verdict: ReviewVerdict
    let summary: String
    let findings: [ReviewFinding]
    let rawMarkdown: String?
    /// USD spent producing this review (Opus call), so the autopilot can fold it
    /// into the run total. 0 when unknown.
    var costUsd: Double = 0

    var blockingFindings: [ReviewFinding] { findings.filter { $0.severity.isBlocking } }
    var isClean: Bool { blockingFindings.isEmpty }
}
