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
}
