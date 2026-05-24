// SPDX-License-Identifier: MIT
import Foundation

/// A single allow / deny rule for the Approval Inbox.
///
/// Matching is two-stage:
///   1. **Tool gate** — `tool` is either an exact tool name (`"Read"`, `"Bash"`)
///      or `"*"` to match any tool.
///   2. **Pattern gate** (optional) — `pattern` is matched against a
///      tool-specific field in the call's input:
///         Read / Write / Edit / NotebookEdit → `file_path`
///         Bash                               → `command`
///         Glob / Grep                        → `pattern`
///         WebFetch                           → `url`
///         WebSearch                          → `query`
///      Patterns are glob (`*`, `**`, `?`) unless prefixed with `re:` for a
///      raw NSRegularExpression. `$WORKTREE` and `$PROJECT` placeholders are
///      expanded against the runtime context before matching, so a rule can
///      portably say "anywhere inside this worktree".
///
/// `behavior == .allow` → short-circuits the approval to accept.
/// `behavior == .deny`  → short-circuits to deny with `reason` as the message.
struct PermissionRule: Hashable, Sendable, Codable {
    var tool: String
    var pattern: String?
    var behavior: Behavior
    var reason: String?
    var scope: Scope

    enum Behavior: String, Codable, Sendable, Hashable {
        case allow
        case deny
    }

    /// Where the rule came from. Surfaced in the UI to explain auto-resolves
    /// and to scope edits (you can only edit per-project rules; profile
    /// defaults are baked in).
    enum Scope: String, Codable, Sendable, Hashable {
        case run            // in-memory, current worker only (cleared on exit)
        case project        // persisted in <project>/.atelier/config.yml
        case profile        // baked into a ProjectProfile
    }

    func matches(toolName: String, inputJSON: String, context: PermissionContext) -> Bool {
        guard tool == "*" || tool == toolName else { return false }
        guard let pattern else { return true }
        let expanded = expand(pattern: pattern, context: context)
        guard let value = Self.extractValue(toolName: toolName, inputJSON: inputJSON) else {
            return false
        }
        return Self.match(pattern: expanded, against: value)
    }

    private func expand(pattern: String, context: PermissionContext) -> String {
        pattern
            .replacingOccurrences(of: "$WORKTREE", with: context.worktreePath)
            .replacingOccurrences(of: "$PROJECT", with: context.projectPath)
    }

    static func extractValue(toolName: String, inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch toolName {
        case "Read", "Write", "Edit", "NotebookEdit":
            return obj["file_path"] as? String
        case "Bash":
            return obj["command"] as? String
        case "Glob", "Grep":
            return obj["pattern"] as? String
        case "WebFetch":
            return obj["url"] as? String
        case "WebSearch":
            return obj["query"] as? String
        default:
            return nil
        }
    }

    /// `re:<regex>` for a raw regex, otherwise glob.
    private static func match(pattern: String, against candidate: String) -> Bool {
        if pattern.hasPrefix("re:") {
            let regex = String(pattern.dropFirst(3))
            return candidate.range(of: regex, options: .regularExpression) != nil
        }
        return globMatch(pattern: pattern, candidate: candidate)
    }

    /// Minimal glob: `*` (no `/`), `**` (cross-segment), `?` (one char).
    private static func globMatch(pattern: String, candidate: String) -> Bool {
        // Translate to regex.
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            switch ch {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    continue
                }
                regex += "[^/]*"
            case "?":
                regex += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                regex += "\\\(ch)"
            default:
                regex.append(ch)
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return candidate.range(of: regex, options: .regularExpression) != nil
    }
}

/// Runtime context passed to `PermissionRule.matches`. Captured per spawn.
struct PermissionContext: Sendable, Hashable {
    let projectId: String
    let projectPath: String
    let worktreePath: String
}

/// Outcome of evaluating a list of rules against an approval request.
enum PermissionEvaluation: Equatable {
    case allow(rule: PermissionRule)
    case deny(rule: PermissionRule)
    case noMatch

    var decision: ApprovalDecision? {
        switch self {
        case .allow:
            return .accept(updatedInput: nil)
        case .deny(let rule):
            return .deny(message: rule.reason ?? "Rule denied this tool call.")
        case .noMatch:
            return nil
        }
    }
}

extension Array where Element == PermissionRule {
    /// First matching rule wins. Rules earlier in the array have priority — the
    /// queue concatenates [run, project, profile] in that order.
    func evaluate(toolName: String, inputJSON: String, context: PermissionContext) -> PermissionEvaluation {
        for rule in self {
            if rule.matches(toolName: toolName, inputJSON: inputJSON, context: context) {
                return rule.behavior == .allow ? .allow(rule: rule) : .deny(rule: rule)
            }
        }
        return .noMatch
    }
}

/// Per-project blanket auto-approve policy, applied *after* explicit allow/deny
/// rules (so a `deny` rule always wins over a blanket auto-approve). Stored on the
/// `Project` record (local DB only — never written to the repo's config.yml — so a
/// permissive setting can't propagate by cloning the repo).
enum AutoApproveLevel: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case off
    case readOnly
    case allButBash
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Ask every time"
        case .readOnly: return "Auto-approve reads"
        case .allButBash: return "Auto-approve all but Bash"
        case .all: return "Auto-approve everything (YOLO)"
        }
    }

    var blurb: String {
        switch self {
        case .off: return "Every tool call waits for you in the Approvals inbox (default)."
        case .readOnly: return "Read, Glob and Grep run automatically; writes and Bash still ask."
        case .allButBash: return "Everything runs automatically except Bash, which still asks."
        case .all: return "Every tool call runs unattended, including Bash."
        }
    }

    var isRisky: Bool { self == .allButBash || self == .all }

    /// Whether this level auto-approves the given tool without prompting.
    func autoApproves(tool: String) -> Bool {
        switch self {
        case .off: return false
        case .readOnly: return ["Read", "Glob", "Grep"].contains(tool)
        case .allButBash: return tool != "Bash"
        case .all: return true
        }
    }
}
