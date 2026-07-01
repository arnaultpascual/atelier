// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

/// Covers the ApprovalQueue step-1.5 auto-accept for first-party MCP capability
/// tools (capability, not permission — the rest of the approval flow is untouched).
///
/// Note: `enqueue` keeps auto-accepted items in `items` with `.resolved` status
/// (UI history), so the meaningful signal is how many stay `.pending` — i.e. how
/// many would actually be shown to a human.
@MainActor
final class ApprovalQueueMCPTests: XCTestCase {

    private func pending(id: String, agent: String, tool: String) -> PendingApproval {
        PendingApproval(id: id, agentId: agent, taskId: nil, projectName: nil,
                        toolName: tool, toolUseId: "", inputJSON: "{}",
                        requestedAt: Date(), status: .pending, continuation: nil)
    }
    private func pendingCount(_ q: ApprovalQueue) -> Int {
        q.items.filter { $0.status == .pending }.count
    }

    func testMCPToolsAutoAcceptedForCapabilityAgent() {
        let q = ApprovalQueue()
        q.setMCPCapability(true, forAgent: "A")
        q.enqueue(pending(id: "1", agent: "A", tool: "mcp__atelier__task_report_progress"))
        q.enqueue(pending(id: "2", agent: "A", tool: "ReadMcpResourceTool"))
        XCTAssertEqual(pendingCount(q), 0)   // both auto-accepted, never shown to the human
    }

    func testMCPToolNotAutoAcceptedWithoutCapabilityFlag() {
        let q = ApprovalQueue()
        q.enqueue(pending(id: "1", agent: "B", tool: "mcp__atelier__task_report_progress"))
        XCTAssertEqual(pendingCount(q), 1)   // no capability flag → queued for the human
    }

    func testNonMCPToolStillQueuedEvenForCapabilityAgent() {
        let q = ApprovalQueue()
        q.setMCPCapability(true, forAgent: "A")
        q.enqueue(pending(id: "1", agent: "A", tool: "Bash"))
        XCTAssertEqual(pendingCount(q), 1)   // approval flow for real tools is untouched
    }

    func testForeignMCPServerToolNotAutoAccepted() {
        let q = ApprovalQueue()
        q.setMCPCapability(true, forAgent: "A")
        q.enqueue(pending(id: "1", agent: "A", tool: "mcp__othersrv__do_thing"))
        XCTAssertEqual(pendingCount(q), 1)   // only our own mcp__atelier__* prefix is first-party
    }

    func testUnloadRulesClearsCapability() {
        let q = ApprovalQueue()
        q.setMCPCapability(true, forAgent: "A")
        q.unloadRules(forAgent: "A")
        q.enqueue(pending(id: "1", agent: "A", tool: "mcp__atelier__task_report_progress"))
        XCTAssertEqual(pendingCount(q), 1)   // capability cleared on unload → queued again
    }
}
