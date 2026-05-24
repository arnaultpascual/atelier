// SPDX-License-Identifier: MIT
import Foundation
import Yams
import os

/// Reads and writes per-project permission rules to
/// `<project>/.atelier/config.yml`.
///
/// On-disk shape (rules live alongside whatever else is in the file —
/// other keys are preserved when we rewrite):
///
/// ```yaml
/// approvals:
///   rules:
///     - tool: Read
///       pattern: "$WORKTREE/**"
///       behavior: allow
///       reason: "read worktree"
///     - tool: Bash
///       pattern: "re:^rm "
///       behavior: deny
///       reason: "never delete from agent"
/// ```
enum ProjectPermissionStore {
    private static let logger = Logger(subsystem: "app.atelier", category: "permissions")

    static func configURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier")
            .appendingPathComponent("config.yml")
    }

    /// Loads the project's rule list. Missing file or missing key → returns [].
    /// All rules returned are tagged `.scope = .project`.
    static func loadRules(projectPath: String) -> [PermissionRule] {
        let url = configURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            guard let top = try Yams.load(yaml: raw) as? [String: Any],
                  let approvals = top["approvals"] as? [String: Any],
                  let rulesArray = approvals["rules"] as? [[String: Any]] else {
                return []
            }
            return rulesArray.compactMap { dict in
                guard let tool = dict["tool"] as? String,
                      let behaviorRaw = dict["behavior"] as? String,
                      let behavior = PermissionRule.Behavior(rawValue: behaviorRaw) else {
                    return nil
                }
                return PermissionRule(
                    tool: tool,
                    pattern: dict["pattern"] as? String,
                    behavior: behavior,
                    reason: dict["reason"] as? String,
                    scope: .project
                )
            }
        } catch {
            logger.error("loadRules failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Appends a rule to the project's config (preserving other top-level keys).
    /// No-op if an equivalent rule already exists.
    static func appendRule(_ rule: PermissionRule, projectPath: String) throws {
        let url = configURL(projectPath: projectPath)
        // Ensure parent exists.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var doc: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path),
           let raw = try? String(contentsOf: url, encoding: .utf8),
           let parsed = try? Yams.load(yaml: raw) as? [String: Any] {
            doc = parsed
        }

        var approvals = (doc["approvals"] as? [String: Any]) ?? [:]
        var rules = (approvals["rules"] as? [[String: Any]]) ?? []

        let candidate = serialise(rule)
        if rules.contains(where: { equal($0, candidate) }) {
            return   // already present, nothing to do
        }
        rules.append(candidate)
        approvals["rules"] = rules
        doc["approvals"] = approvals

        let yaml = try Yams.dump(object: doc, allowUnicode: true, sortKeys: false)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the first matching rule (by tool+pattern+behavior). Returns true
    /// if anything was removed.
    @discardableResult
    static func removeRule(matching rule: PermissionRule, projectPath: String) throws -> Bool {
        let url = configURL(projectPath: projectPath)
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8),
              var doc = try Yams.load(yaml: raw) as? [String: Any] else {
            return false
        }
        var approvals = (doc["approvals"] as? [String: Any]) ?? [:]
        var rules = (approvals["rules"] as? [[String: Any]]) ?? []
        let candidate = serialise(rule)
        guard let idx = rules.firstIndex(where: { equal($0, candidate) }) else {
            return false
        }
        rules.remove(at: idx)
        approvals["rules"] = rules
        doc["approvals"] = approvals
        let yaml = try Yams.dump(object: doc, allowUnicode: true, sortKeys: false)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private static func serialise(_ rule: PermissionRule) -> [String: Any] {
        var out: [String: Any] = [
            "tool": rule.tool,
            "behavior": rule.behavior.rawValue
        ]
        if let p = rule.pattern { out["pattern"] = p }
        if let r = rule.reason { out["reason"] = r }
        return out
    }

    private static func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        (a["tool"] as? String) == (b["tool"] as? String)
            && (a["pattern"] as? String) == (b["pattern"] as? String)
            && (a["behavior"] as? String) == (b["behavior"] as? String)
    }
}
