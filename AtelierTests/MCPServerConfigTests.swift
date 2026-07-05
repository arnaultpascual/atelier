// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class MCPServerConfigTests: XCTestCase {

    private func args(_ payload: [String: Any]) throws -> [String] {
        let v = try MCPCodec.decoder.decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        return v["mcpServers"]?["atelier"]?["args"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    func testPayloadWithTaskId() throws {
        let payload = MCPServerConfig.buildConfigPayload(
            serverName: "atelier", command: "/x/AtelierMCPServer", socketPath: "/tmp/s.sock",
            featureId: "F1", taskId: "T1", projectPath: "/p", agentId: "A1")
        let v = try MCPCodec.decoder.decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(v["mcpServers"]?["atelier"]?["command"]?.stringValue, "/x/AtelierMCPServer")
        XCTAssertEqual(try args(payload),
            ["--socket", "/tmp/s.sock", "--feature-id", "F1", "--task-id", "T1",
             "--project-path", "/p", "--agent-id", "A1"])
    }

    func testPayloadWithoutTaskIdOmitsFlag() throws {
        let payload = MCPServerConfig.buildConfigPayload(
            serverName: "atelier", command: "/x", socketPath: "/s",
            featureId: "F1", taskId: nil, projectPath: "/p", agentId: "A1")
        let a = try args(payload)
        XCTAssertFalse(a.contains("--task-id"))
        XCTAssertEqual(a.first, "--socket")
        XCTAssertTrue(a.contains("--feature-id"))
    }

    func testPayloadEmptyTaskIdOmitsFlag() throws {
        let payload = MCPServerConfig.buildConfigPayload(
            serverName: "atelier", command: "/x", socketPath: "/s",
            featureId: "F1", taskId: "", projectPath: "/p", agentId: "A1")
        XCTAssertFalse(try args(payload).contains("--task-id"))
    }
}
