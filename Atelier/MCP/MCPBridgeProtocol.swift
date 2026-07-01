// SPDX-License-Identifier: MIT
//
// Wire protocol for the Unix-socket bridge between `AtelierMCPServer` (the
// stdio MCP executable a claude worker talks to) and the running Atelier app
// (`AtelierBridgeListener`). Mutating / real-time tools round-trip over this
// socket so the app stays the single GRDB writer on @MainActor.
//
// Framing: newline-delimited compact JSON, both directions (mirrors the
// approval bridge). JSON escapes inner newlines, so multi-line payloads (a
// brief/spec resource body) travel safely on one line.
//
// Pure Foundation — compiled into both the app and the tool target.

import Foundation

/// server → app
public struct BridgeRequest: Codable, Sendable, Equatable {
    public let id: String
    /// Operation name, e.g. "task_report_progress", "resource_read".
    public let op: String
    public let featureId: String?
    public let taskId: String?
    /// Operation arguments as a JSON object.
    public let args: JSONValue

    public init(id: String, op: String, featureId: String?, taskId: String?, args: JSONValue) {
        self.id = id; self.op = op; self.featureId = featureId; self.taskId = taskId; self.args = args
    }
}

/// app → server
public struct BridgeResponse: Codable, Sendable, Equatable {
    public let id: String
    public let ok: Bool
    /// Present when `ok`; shape depends on `op` (e.g. `{ "text": "…" }` for a resource).
    public let result: JSONValue?
    /// Present when `!ok`.
    public let error: String?

    public init(id: String, ok: Bool, result: JSONValue?, error: String?) {
        self.id = id; self.ok = ok; self.result = result; self.error = error
    }
    public static func success(id: String, result: JSONValue?) -> BridgeResponse {
        .init(id: id, ok: true, result: result, error: nil)
    }
    public static func failure(id: String, error: String) -> BridgeResponse {
        .init(id: id, ok: false, result: nil, error: error)
    }
}

/// Abstraction over the socket round-trip. `AtelierMCPServer` provides a real
/// implementation; tests provide an in-process fake so `MCPServerCore` can be
/// exercised without a running app.
public protocol MCPBridge: Sendable {
    /// Sends a request to the app and awaits its response. Implementations must
    /// tolerate a missing/unreachable app and surface it as a `failure`, never
    /// hang the worker (the file+git contract remains the fallback).
    func send(_ request: BridgeRequest) async -> BridgeResponse
}
