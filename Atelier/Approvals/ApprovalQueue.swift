// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Cross-workspace queue of pending tool-call approvals from worker agents.
///
/// The helper subprocess relays each `approval_prompt` MCP call to Atelier
/// over a Unix domain socket. `ApprovalSocketListener` decodes the request,
/// inserts a `PendingApproval` here, and parks a continuation. The UI shows
/// the queue (badge + sheet) and routes the user's choice back to the
/// continuation, which writes the JSON response down the socket.
@MainActor
@Observable
final class ApprovalQueue {
    private(set) var items: [PendingApproval] = []
    /// Total items resolved this session — useful for the sidebar badge to
    /// avoid flickering when items move to .resolved.
    private(set) var resolvedCount: Int = 0

    /// Identifier of the currently-focused agent run, if any. Used to default
    /// the inbox sheet's filter.
    var focusedAgentId: String?

    /// Auto-accept rules scoped to a single live worker (keyed by agentId).
    /// Cleared when the worker exits. Set by the "Always accept <tool> for
    /// this run" affordance on each card.
    private var autoAcceptTools: [String: Set<String>] = [:]

    /// Agents running under the autopilot (FeatureBuildRunner). For these, any approval the
    /// project's deny rules didn't already block is auto-accepted — there's no human watching
    /// the inbox during an autonomous run.
    private var autopilotAgents: Set<String> = []

    /// Composite rule lists keyed by agentId, in evaluation order: per-run
    /// (added on the fly) → per-project (loaded from config.yml) → profile
    /// defaults. First matching rule wins.
    private var perAgentRules: [String: [PermissionRule]] = [:]
    private var perAgentContext: [String: PermissionContext] = [:]
    private var perAgentProject: [String: Project] = [:]

    var pending: [PendingApproval] {
        items.filter { $0.status == .pending }
    }

    var pendingCount: Int { pending.count }

    /// Called by TaskSpawner before a worker starts. Composes the rule list
    /// from project + profile sources and remembers the context for pattern
    /// expansion ($WORKTREE / $PROJECT).
    func loadRules(forAgent agentId: String,
                   project: Project,
                   worktreePath: String) {
        let projectRules = ProjectPermissionStore.loadRules(projectPath: project.path)
        let profileRules = (ProjectProfile.find(id: project.profileId) ?? .generic).defaultRules
        // Order: run rules are prepended on demand; project first, profile last
        perAgentRules[agentId] = projectRules + profileRules
        perAgentContext[agentId] = PermissionContext(
            projectId: project.id,
            projectPath: project.path,
            worktreePath: worktreePath
        )
        perAgentProject[agentId] = project
    }

    func unloadRules(forAgent agentId: String) {
        perAgentRules.removeValue(forKey: agentId)
        perAgentContext.removeValue(forKey: agentId)
        perAgentProject.removeValue(forKey: agentId)
        autopilotAgents.remove(agentId)
    }

    /// Marks (or unmarks) an agent as autopilot-driven. While set, `enqueue` auto-accepts any
    /// approval not already blocked by a project deny rule.
    func setAutopilot(_ on: Bool, forAgent agentId: String) {
        if on { autopilotAgents.insert(agentId) } else { autopilotAgents.remove(agentId) }
    }

    /// Returns the project handle the inbox should use when offering "Always
    /// in this project" actions on a card.
    func project(forAgent agentId: String) -> Project? {
        perAgentProject[agentId]
    }

    func context(forAgent agentId: String) -> PermissionContext? {
        perAgentContext[agentId]
    }

    func enqueue(_ approval: PendingApproval) {
        // 1. Per-run tool whitelist (the original "Always for this run" path).
        if let allowed = autoAcceptTools[approval.agentId],
           allowed.contains(approval.toolName) {
            resolveImmediately(approval, with: .accept(updatedInput: nil))
            return
        }
        // 2. Per-project + profile rules.
        if let rules = perAgentRules[approval.agentId],
           let context = perAgentContext[approval.agentId] {
            let outcome = rules.evaluate(
                toolName: approval.toolName,
                inputJSON: approval.inputJSON,
                context: context
            )
            if let decision = outcome.decision {
                resolveImmediately(approval, with: decision)
                return
            }
        }
        // 2.5 Autopilot: no human is watching the inbox, so auto-accept anything the project's
        //     deny rules (step 2) didn't already block — deny still wins.
        if autopilotAgents.contains(approval.agentId) {
            resolveImmediately(approval, with: .accept(updatedInput: nil))
            return
        }
        // 3. Per-project auto-approve level. Reached only on no-match above, so an
        //    explicit deny rule still takes precedence over a blanket auto-approve.
        if let project = perAgentProject[approval.agentId],
           let level = project.autoApproveLevel,
           level.autoApproves(tool: approval.toolName) {
            resolveImmediately(approval, with: .accept(updatedInput: nil))
            return
        }
        items.append(approval)
    }

    private func resolveImmediately(_ approval: PendingApproval, with decision: ApprovalDecision) {
        var resolved = approval
        resolved.status = .resolved(decision: decision, at: Date())
        resolved.continuation?.resume(returning: decision)
        resolved.continuation = nil
        items.append(resolved)
        resolvedCount += 1
    }

    /// Whitelists a tool for the rest of this agent run. Resolves any already-
    /// pending approvals for that (agentId, tool) tuple immediately.
    func alwaysAccept(toolName: String, forAgent agentId: String) {
        autoAcceptTools[agentId, default: []].insert(toolName)
        for idx in items.indices where items[idx].agentId == agentId
                                       && items[idx].toolName == toolName
                                       && items[idx].status == .pending {
            items[idx].continuation?.resume(returning: .accept(updatedInput: nil))
            items[idx].continuation = nil
            items[idx].status = .resolved(decision: .accept(updatedInput: nil), at: Date())
            resolvedCount += 1
        }
    }

    func isAutoAccepted(toolName: String, forAgent agentId: String) -> Bool {
        autoAcceptTools[agentId]?.contains(toolName) ?? false
    }

    func autoAcceptedSummary(forAgent agentId: String) -> [String] {
        Array(autoAcceptTools[agentId] ?? []).sorted()
    }

    /// Mark resolved and notify the caller awaiting the decision.
    func resolve(id: String, with decision: ApprovalDecision) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .resolved(decision: decision, at: Date())
        items[idx].continuation?.resume(returning: decision)
        items[idx].continuation = nil
        resolvedCount += 1
    }

    /// Drop all resolved items older than a few seconds; called by the UI when
    /// an agent ends, to keep the queue tidy.
    func purgeResolved(olderThan: TimeInterval = 30) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        items.removeAll { item in
            if case .resolved(_, let at) = item.status, at < cutoff { return true }
            return false
        }
    }

    /// Resolve any still-pending approvals from a specific agent. Called when
    /// the worker exits unexpectedly so we don't leave the helper deadlocked
    /// (or the user staring at a stale card).
    func cancelPending(forAgent agentId: String, reason: String) {
        for idx in items.indices where items[idx].agentId == agentId && items[idx].status == .pending {
            items[idx].continuation?.resume(returning: .deny(message: reason))
            items[idx].continuation = nil
            items[idx].status = .resolved(decision: .deny(message: reason), at: Date())
        }
        // Forget any per-run whitelist — the next spawn on the same agentId
        // starts fresh.
        autoAcceptTools.removeValue(forKey: agentId)
        unloadRules(forAgent: agentId)
    }

    /// Persists a rule to the project's config and re-evaluates any pending
    /// approvals against it (so if there are queued items that match, they
    /// resolve immediately).
    func persistProjectRule(_ rule: PermissionRule, project: Project, agentId: String) throws {
        try ProjectPermissionStore.appendRule(rule, projectPath: project.path)
        // Refresh the in-memory rule list for the active worker so the new
        // rule takes effect for in-flight queued approvals.
        if perAgentRules[agentId] != nil {
            let projectRules = ProjectPermissionStore.loadRules(projectPath: project.path)
            let profileRules = (ProjectProfile.find(id: project.profileId) ?? .generic).defaultRules
            perAgentRules[agentId] = projectRules + profileRules
        }
        guard let context = perAgentContext[agentId] else { return }
        // Re-evaluate pending items against the updated rule set.
        for idx in items.indices where items[idx].agentId == agentId
                                       && items[idx].status == .pending {
            let outcome = (perAgentRules[agentId] ?? []).evaluate(
                toolName: items[idx].toolName,
                inputJSON: items[idx].inputJSON,
                context: context
            )
            if let decision = outcome.decision {
                items[idx].continuation?.resume(returning: decision)
                items[idx].continuation = nil
                items[idx].status = .resolved(decision: decision, at: Date())
                resolvedCount += 1
            }
        }
    }
}

struct PendingApproval: Identifiable {
    let id: String
    let agentId: String
    let taskId: String?
    let projectName: String?
    let toolName: String
    let toolUseId: String
    let inputJSON: String
    let requestedAt: Date
    var status: Status = .pending
    var continuation: CheckedContinuation<ApprovalDecision, Never>?

    enum Status: Equatable {
        case pending
        case resolved(decision: ApprovalDecision, at: Date)
    }

    /// Best-effort one-line description suitable for inbox cards.
    var summaryLine: String {
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return inputJSON
        }
        switch toolName {
        case "Bash":
            return (obj["command"] as? String) ?? inputJSON
        case "Read", "Write", "Edit", "NotebookEdit":
            return (obj["file_path"] as? String) ?? inputJSON
        case "Glob", "Grep":
            let p = obj["pattern"] as? String ?? ""
            let path = obj["path"] as? String ?? ""
            return path.isEmpty ? p : "\(p) in \(path)"
        case "WebFetch":
            return (obj["url"] as? String) ?? inputJSON
        case "WebSearch":
            return (obj["query"] as? String) ?? inputJSON
        default:
            return inputJSON
        }
    }
}

enum ApprovalDecision: Equatable {
    case accept(updatedInput: String?)        // updatedInput nil = use original
    case deny(message: String)                // ignore + respond both land here

    var label: String {
        switch self {
        case .accept: return "accept"
        case .deny: return "deny"
        }
    }
}
