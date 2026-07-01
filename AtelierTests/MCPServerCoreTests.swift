// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

/// In-process fake of the app-side socket bridge — records requests and replies
/// via a caller-supplied closure. Lets us exercise MCPServerCore with no app.
actor FakeBridge: MCPBridge {
    private(set) var received: [BridgeRequest] = []
    private let responder: @Sendable (BridgeRequest) -> BridgeResponse

    init(responder: @escaping @Sendable (BridgeRequest) -> BridgeResponse) {
        self.responder = responder
    }
    func send(_ request: BridgeRequest) async -> BridgeResponse {
        received.append(request)
        return responder(request)
    }
    func lastRequest() -> BridgeRequest? { received.last }
    var count: Int { received.count }
}

final class MCPServerCoreTests: XCTestCase {

    private func core(feature: String? = "F1", task: String? = "T1") -> MCPServerCore {
        MCPServerCore(context: MCPContext(featureId: feature, taskId: task, projectPath: "/tmp/proj"))
    }
    private func req(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> JSONRPCRequest {
        JSONRPCRequest(id: .number(id), method: method, params: params)
    }
    private func alwaysOK() -> FakeBridge {
        FakeBridge { r in .success(id: r.id, result: .object(["text": .string("BODY"), "mimeType": .string("text/markdown")])) }
    }

    func testNotificationReturnsNil() async {
        let r = await core().handle(JSONRPCRequest(id: nil, method: "notifications/initialized", params: nil), bridge: alwaysOK())
        XCTAssertNil(r)
    }

    func testInitializeEchoesProtocolAndServerInfo() async {
        let params: JSONValue = .object(["protocolVersion": .string("2025-06-18")])
        let r = await core().handle(req(1, "initialize", params), bridge: alwaysOK())
        XCTAssertEqual(r?.result?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(r?.result?["serverInfo"]?["name"]?.stringValue, "atelier")
        XCTAssertNotNil(r?.result?["capabilities"]?["tools"])
    }

    func testInitializeDefaultsProtocolWhenMissing() async {
        let r = await core().handle(req(1, "initialize", nil), bridge: alwaysOK())
        XCTAssertEqual(r?.result?["protocolVersion"]?.stringValue, MCPServerCore.defaultProtocolVersion)
    }

    func testToolsListContainsReportProgress() async {
        let r = await core().handle(req(2, "tools/list"), bridge: alwaysOK())
        let names = r?.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("task_report_progress"))
        // No dotted names ever (Claude would drop them).
        XCTAssertFalse(names.contains { $0.contains(".") })
    }

    func testReportProgressHappyPathRoutesToBridge() async {
        let bridge = alwaysOK()
        let params: JSONValue = .object(["name": .string("task_report_progress"),
                                         "arguments": .object(["pct": .int(42), "note": .string("go")])])
        let r = await core().handle(req(3, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, false)
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "task_report_progress")
        XCTAssertEqual(sent?.taskId, "T1")           // fell back to context task
        XCTAssertEqual(sent?.featureId, "F1")
        XCTAssertEqual(sent?.args["pct"]?.intValue, 42)
        XCTAssertEqual(sent?.args["note"]?.stringValue, "go")
    }

    func testReportProgressClampsAndUsesExplicitTaskId() async {
        let bridge = alwaysOK()
        let params: JSONValue = .object(["name": .string("task_report_progress"),
                                         "arguments": .object(["pct": .int(250), "taskId": .string("T9")])])
        _ = await core().handle(req(4, "tools/call", params), bridge: bridge)
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.args["pct"]?.intValue, 100)   // clamped
        XCTAssertEqual(sent?.taskId, "T9")
    }

    func testReportProgressMissingPctIsToolError() async {
        let bridge = alwaysOK()
        let params: JSONValue = .object(["name": .string("task_report_progress"),
                                         "arguments": .object(["taskId": .string("T1")])])
        let r = await core().handle(req(5, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, true)   // MCP tool error, not JSON-RPC error
        let count = await bridge.count
        XCTAssertEqual(count, 0)                                 // never hit the bridge
    }

    func testReportProgressBridgeFailureSurfacesAsToolError() async {
        let bridge = FakeBridge { r in .failure(id: r.id, error: "app not loaded") }
        let params: JSONValue = .object(["name": .string("task_report_progress"),
                                         "arguments": .object(["pct": .int(10)])])
        let r = await core().handle(req(6, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, true)
        XCTAssertNil(r?.error)   // worker keeps going; not a JSON-RPC-level error
    }

    func testUnknownToolIsInvalidParams() async {
        let params: JSONValue = .object(["name": .string("does_not_exist"), "arguments": .object([:])])
        let r = await core().handle(req(7, "tools/call", params), bridge: alwaysOK())
        XCTAssertEqual(r?.error?.code, -32602)
    }

    func testResourcesListScopedToFeature() async {
        let uris = await core().handle(req(8, "resources/list"), bridge: alwaysOK())
            .flatMap { $0.result?["resources"]?.arrayValue }?.compactMap { $0["uri"]?.stringValue } ?? []
        XCTAssertTrue(uris.contains("atelier://feature/F1/spec"))
        XCTAssertTrue(uris.contains("atelier://feature/F1/brief"))
    }

    func testResourcesListEmptyWithoutFeature() async {
        let r = await core(feature: nil).handle(req(9, "resources/list"), bridge: alwaysOK())
        XCTAssertEqual(r?.result?["resources"]?.arrayValue?.count, 0)
    }

    func testResourceReadReturnsContents() async {
        let bridge = alwaysOK()
        let params: JSONValue = .object(["uri": .string("atelier://feature/F1/spec")])
        let r = await core().handle(req(10, "resources/read", params), bridge: bridge)
        let contents = r?.result?["contents"]?.arrayValue
        XCTAssertEqual(contents?.first?["text"]?.stringValue, "BODY")
        XCTAssertEqual(contents?.first?["uri"]?.stringValue, "atelier://feature/F1/spec")
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "resource_read")
    }

    func testResourceReadFailureIsJSONRPCError() async {
        let bridge = FakeBridge { r in .failure(id: r.id, error: "no such feature") }
        let params: JSONValue = .object(["uri": .string("atelier://feature/F1/spec")])
        let r = await core().handle(req(11, "resources/read", params), bridge: bridge)
        XCTAssertNil(r?.result)
        XCTAssertEqual(r?.error?.code, -32603)
    }

    func testUnknownMethodIsMethodNotFound() async {
        let r = await core().handle(req(12, "does/not/exist"), bridge: alwaysOK())
        XCTAssertEqual(r?.error?.code, -32601)
    }

    func testReportProgressHugePctIsToolErrorNotCrash() async {
        let bridge = alwaysOK()
        let params: JSONValue = .object(["name": .string("task_report_progress"),
                                         "arguments": .object(["pct": .double(1e30), "taskId": .string("T1")])])
        let r = await core().handle(req(13, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, true)   // rejected, not crashed
        let count = await bridge.count
        XCTAssertEqual(count, 0)                                 // never reached the bridge
    }

    func testInitializeRejectsUnsupportedProtocolAndAdvertisesPrompts() async {
        let params: JSONValue = .object(["protocolVersion": .string("1999-01-01")])
        let r = await core().handle(req(14, "initialize", params), bridge: alwaysOK())
        XCTAssertEqual(r?.result?["protocolVersion"]?.stringValue, MCPServerCore.defaultProtocolVersion)
        XCTAssertNotNil(r?.result?["capabilities"]?["prompts"])
    }

    // MARK: Phase 2/3 tools

    private func ackBridge(_ msg: String = "ok") -> FakeBridge {
        FakeBridge { r in .success(id: r.id, result: .object(["message": .string(msg)])) }
    }

    func testToolsListContainsFullSurfaceAndNoDots() async {
        let names = await core().handle(req(30, "tools/list"), bridge: alwaysOK())
            .flatMap { $0.result?["tools"]?.arrayValue }?.compactMap { $0["name"]?.stringValue } ?? []
        for expected in ["brief_add_requirement", "brief_resolve_open_question", "spec_record_finding",
                         "task_update_status", "task_get_dependencies", "wave_mark_done",
                         "plan_next_wave", "coverage_get", "coverage_uncovered", "test_report_run", "review_request"] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
        XCTAssertFalse(names.contains { $0.contains(".") })
    }

    func testBriefMutationForwardsArgsAndAcks() async {
        let bridge = ackBridge("Requirement added.")
        let params: JSONValue = .object(["name": .string("brief_add_requirement"),
                                         "arguments": .object(["text": .string("be fast"), "priority": .string("high")])])
        let r = await core().handle(req(31, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, false)
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "brief_add_requirement")
        XCTAssertEqual(sent?.featureId, "F1")
        XCTAssertEqual(sent?.args["text"]?.stringValue, "be fast")
        XCTAssertEqual(sent?.args["priority"]?.stringValue, "high")
    }

    func testSpecRecordFindingForwards() async {
        let bridge = ackBridge()
        let params: JSONValue = .object(["name": .string("spec_record_finding"),
                                         "arguments": .object(["finding": .string("API lacks X"), "workaround": .string("poll")])])
        _ = await core().handle(req(32, "tools/call", params), bridge: bridge)
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "spec_record_finding")
        XCTAssertEqual(sent?.args["finding"]?.stringValue, "API lacks X")
    }

    func testTaskUpdateStatusFallsBackToContextTask() async {
        let bridge = ackBridge()
        let params: JSONValue = .object(["name": .string("task_update_status"),
                                         "arguments": .object(["status": .string("Done")])])
        _ = await core().handle(req(33, "tools/call", params), bridge: bridge)
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "task_update_status")
        XCTAssertEqual(sent?.taskId, "T1")   // from context
        XCTAssertEqual(sent?.args["status"]?.stringValue, "Done")
    }

    func testQueryToolRendersAppText() async {
        let bridge = FakeBridge { r in .success(id: r.id, result: .object(["text": .string("Coverage 72% vs 90% (gap 18) [swift]")])) }
        let params: JSONValue = .object(["name": .string("coverage_get"), "arguments": .object([:])])
        let r = await core().handle(req(34, "tools/call", params), bridge: bridge)
        let text = r?.result?["content"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertEqual(text, "Coverage 72% vs 90% (gap 18) [swift]")
        let sent = await bridge.lastRequest()
        XCTAssertEqual(sent?.op, "coverage_get")
    }

    func testForwardingToolWithoutFeatureIsToolError() async {
        let bridge = ackBridge()
        let params: JSONValue = .object(["name": .string("brief_add_requirement"),
                                         "arguments": .object(["text": .string("x")])])
        let r = await core(feature: nil).handle(req(35, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, true)
        let count = await bridge.count
        XCTAssertEqual(count, 0)   // never hit the bridge without a feature
    }

    func testBridgeFailureOnMutationIsToolErrorNotRPCError() async {
        let bridge = FakeBridge { r in .failure(id: r.id, error: "app not loaded") }
        let params: JSONValue = .object(["name": .string("task_update_status"),
                                         "arguments": .object(["status": .string("Done")])])
        let r = await core().handle(req(36, "tools/call", params), bridge: bridge)
        XCTAssertEqual(r?.result?["isError"]?.boolValue, true)
        XCTAssertNil(r?.error)
    }

    // MARK: Prompts (Phase 4)

    func testPromptsListHasFourNoDotNames() async {
        let names = await core().handle(req(40, "prompts/list"), bridge: alwaysOK())
            .flatMap { $0.result?["prompts"]?.arrayValue }?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(Set(names), ["atelier_decompose", "atelier_refine_brief", "atelier_review", "atelier_synthesize_feature"])
        XCTAssertFalse(names.contains { $0.contains(".") })
    }

    func testPromptsGetRendersArgsAndDefaults() async {
        let params: JSONValue = .object(["name": .string("atelier_review"),
                                         "arguments": .object(["task_title": .string("Add login")])])
        let r = await core().handle(req(41, "prompts/get", params), bridge: alwaysOK())
        let text = r?.result?["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("Add login"))       // provided arg
        XCTAssertTrue(text.contains("base branch main")) // default substituted
        XCTAssertFalse(text.contains("{{"))              // no unsubstituted placeholders
    }

    func testPromptsGetUnknownIsInvalidParams() async {
        let r = await core().handle(req(42, "prompts/get", .object(["name": .string("nope")])), bridge: alwaysOK())
        XCTAssertEqual(r?.error?.code, -32602)
    }
}
