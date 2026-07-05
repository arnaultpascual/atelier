// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class MCPBridgeProtocolTests: XCTestCase {

    func testBridgeRequestRoundTrip() throws {
        let req = BridgeRequest(
            id: "r1", op: "task_report_progress",
            featureId: "F1", taskId: "T1",
            args: .object(["pct": .int(42), "note": .string("wiring the socket")])
        )
        let data = try MCPCodec.encoder.encode(req)
        let decoded = try MCPCodec.decoder.decode(BridgeRequest.self, from: data)
        XCTAssertEqual(decoded, req)
    }

    func testBridgeRequestNilScopeOmitsFields() throws {
        let req = BridgeRequest(id: "r2", op: "resource_read", featureId: nil, taskId: nil,
                                args: .object(["uri": .string("atelier://feature/F/spec")]))
        let decoded = try MCPCodec.decoder.decode(BridgeRequest.self, from: MCPCodec.encoder.encode(req))
        XCTAssertNil(decoded.featureId)
        XCTAssertNil(decoded.taskId)
        XCTAssertEqual(decoded.args["uri"]?.stringValue, "atelier://feature/F/spec")
    }

    func testBridgeResponseSuccessAndFailure() throws {
        let ok = BridgeResponse.success(id: "r1", result: .object(["text": .string("# Spec")]))
        let okDecoded = try MCPCodec.decoder.decode(BridgeResponse.self, from: MCPCodec.encoder.encode(ok))
        XCTAssertTrue(okDecoded.ok)
        XCTAssertEqual(okDecoded.result?["text"]?.stringValue, "# Spec")
        XCTAssertNil(okDecoded.error)

        let fail = BridgeResponse.failure(id: "r1", error: "not found")
        let failDecoded = try MCPCodec.decoder.decode(BridgeResponse.self, from: MCPCodec.encoder.encode(fail))
        XCTAssertFalse(failDecoded.ok)
        XCTAssertEqual(failDecoded.error, "not found")
    }
}
