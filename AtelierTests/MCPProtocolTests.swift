// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class MCPProtocolTests: XCTestCase {

    // MARK: JSONValue

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "s": .string("hi"),
            "i": .int(42),
            "d": .double(3.5),
            "b": .bool(true),
            "n": .null,
            "arr": .array([.int(1), .string("two"), .bool(false)]),
            "nested": .object(["k": .string("v")]),
        ])
        let data = try MCPCodec.encoder.encode(value)
        let decoded = try MCPCodec.decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testIntStaysIntAndDoubleStaysDouble() throws {
        XCTAssertEqual(try MCPCodec.decoder.decode(JSONValue.self, from: Data("3".utf8)), .int(3))
        XCTAssertEqual(try MCPCodec.decoder.decode(JSONValue.self, from: Data("3.5".utf8)), .double(3.5))
        XCTAssertEqual(try MCPCodec.decoder.decode(JSONValue.self, from: Data("true".utf8)), .bool(true))
        XCTAssertEqual(try MCPCodec.decoder.decode(JSONValue.self, from: Data("null".utf8)), .null)
    }

    func testJSONValueAccessors() {
        let v: JSONValue = .object(["a": .int(5), "b": .string("x"), "f": .double(2.0)])
        XCTAssertEqual(v["a"]?.intValue, 5)
        XCTAssertEqual(v["b"]?.stringValue, "x")
        XCTAssertEqual(v["f"]?.intValue, 2)          // whole double coerces to int
        XCTAssertNil(v["missing"])
        XCTAssertNil(JSONValue.string("x")["k"])     // subscript on non-object
    }

    // MARK: Request decoding

    func testDecodeRequestWithNumberId() {
        let req = MCPCodec.decodeRequest(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8))
        XCTAssertEqual(req?.id, .number(7))
        XCTAssertEqual(req?.method, "tools/list")
        XCTAssertFalse(req?.isNotification ?? true)
    }

    func testDecodeRequestWithStringId() {
        let req = MCPCodec.decodeRequest(Data(#"{"jsonrpc":"2.0","id":"abc","method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8))
        XCTAssertEqual(req?.id, .string("abc"))
        XCTAssertEqual(req?.params?["protocolVersion"]?.stringValue, "2025-06-18")
    }

    func testDecodeNotificationHasNoId() {
        let req = MCPCodec.decodeRequest(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNotNil(req)
        XCTAssertTrue(req?.isNotification ?? false)
    }

    func testDecodeMalformedReturnsNil() {
        XCTAssertNil(MCPCodec.decodeRequest(Data("not json".utf8)))
        XCTAssertNil(MCPCodec.decodeRequest(Data("{}".utf8)))  // missing method
    }

    // MARK: Response encoding

    func testEncodeSuccessResponse() throws {
        let resp = JSONRPCResponse.success(id: .number(1), result: .object(["ok": .bool(true)]))
        let obj = try MCPCodec.decoder.decode(JSONValue.self, from: MCPCodec.encodeResponse(resp))
        XCTAssertEqual(obj["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(obj["id"]?.intValue, 1)
        XCTAssertEqual(obj["result"]?["ok"]?.boolValue, true)
        XCTAssertNil(obj["error"])
    }

    func testEncodeErrorResponseOmitsResult() throws {
        let resp = JSONRPCResponse.failure(id: .string("x"), error: .methodNotFound("foo/bar"))
        let obj = try MCPCodec.decoder.decode(JSONValue.self, from: MCPCodec.encodeResponse(resp))
        XCTAssertEqual(obj["error"]?["code"]?.intValue, -32601)
        XCTAssertNotNil(obj["error"]?["message"]?.stringValue)
        XCTAssertNil(obj["result"])
    }

    func testEncodeNullIdForParseError() throws {
        let resp = JSONRPCResponse.failure(id: nil, error: .parseError())
        let obj = try MCPCodec.decoder.decode(JSONValue.self, from: MCPCodec.encodeResponse(resp))
        XCTAssertEqual(obj["id"], .null)
    }

    // MARK: intValue safety (regression: Int(d) trap on bogus pct)

    func testIntValueNeverTrapsOnHugeOrFractionalDouble() {
        XCTAssertNil(JSONValue.double(1e30).intValue)
        XCTAssertNil(JSONValue.double(-1e30).intValue)
        XCTAssertNil(JSONValue.double(2.5).intValue)
        XCTAssertNil(JSONValue.double(.nan).intValue)
        XCTAssertNil(JSONValue.double(.infinity).intValue)
        XCTAssertEqual(JSONValue.double(2.0).intValue, 2)   // whole double still coerces
    }

    func testHugeNumberDecodesToDoubleAndIntValueIsNil() throws {
        let v = try MCPCodec.decoder.decode(JSONValue.self, from: Data("1e30".utf8))
        guard case .double = v else { return XCTFail("expected .double, got \(v)") }
        XCTAssertNil(v.intValue)   // must not trap
    }

    // MARK: id edge cases

    func testExplicitNullIdIsNotNotification() {
        let req = MCPCodec.decodeRequest(Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#.utf8))
        XCTAssertNotNil(req)
        XCTAssertFalse(req?.isNotification ?? true)   // present-but-null → real request
        XCTAssertEqual(req?.id, .null)
    }

    func testFractionalIdRoundTrips() throws {
        let req = MCPCodec.decodeRequest(Data(#"{"jsonrpc":"2.0","id":1.5,"method":"x"}"#.utf8))
        XCTAssertEqual(req?.id, .double(1.5))
        let obj = try MCPCodec.decoder.decode(JSONValue.self,
                    from: MCPCodec.encodeResponse(.success(id: req?.id, result: .bool(true))))
        XCTAssertEqual(obj["id"]?.doubleValue, 1.5)
    }
}
