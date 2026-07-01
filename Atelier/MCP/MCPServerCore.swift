// SPDX-License-Identifier: MIT
//
// The MCP method dispatcher. Pure logic: given a decoded JSON-RPC request and
// an `MCPBridge`, it produces the JSON-RPC response — no stdio, no sockets, no
// app dependencies. `AtelierMCPServer/main.swift` wires real stdin/stdout and a
// real socket bridge around it; `AtelierTests` drives it with a fake bridge.
//
// Phase 1 surface (walking skeleton):
//   tool     task_report_progress(taskId, pct, note?)  → live kanban %
//   resource atelier://feature/{id}/spec               → living brief.md
//   resource atelier://feature/{id}/brief              → same living file
//
// Naming: MCP tool names use underscores, never dots — Claude maps them to
// `mcp__atelier__<name>` and the API name regex is ^[a-zA-Z0-9_-]{1,64}$;
// a dotted name is silently dropped (verified against claude 2.1.190).

import Foundation

/// Per-spawn context, sourced from the `AtelierMCPServer` CLI args.
public struct MCPContext: Sendable, Equatable {
    public let featureId: String?
    public let taskId: String?
    public let projectPath: String?
    public let serverName: String
    public let serverVersion: String

    public init(featureId: String?, taskId: String?, projectPath: String?,
                serverName: String = "atelier", serverVersion: String = "1.0.0") {
        self.featureId = featureId
        self.taskId = taskId
        self.projectPath = projectPath
        self.serverName = serverName
        self.serverVersion = serverVersion
    }
}

public struct MCPServerCore: Sendable {
    public let context: MCPContext
    public static let defaultProtocolVersion = "2025-06-18"
    public static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(context: MCPContext) {
        self.context = context
    }

    // MARK: Tool & resource definitions

    struct ToolDef: Sendable {
        let name: String
        let description: String
        let inputSchema: JSONValue
        var json: JSONValue {
            .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
        }
    }

    var tools: [ToolDef] {
        [
            ToolDef(
                name: "task_report_progress",
                description: "Report live build progress for a task so it shows in Atelier's kanban. Call periodically as you work (0–100).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "taskId": .object(["type": .string("string"), "description": .string("Task id; defaults to the current task if omitted.")]),
                        "pct": .object(["type": .string("integer"), "description": .string("Percent complete, 0–100.")]),
                        "note": .object(["type": .string("string"), "description": .string("Optional short status note.")]),
                    ]),
                    "required": .array([.string("pct")]),
                ])
            )
        ]
    }

    var resources: [JSONValue] {
        guard let fid = context.featureId else { return [] }
        return [
            .object([
                "uri": .string("atelier://feature/\(fid)/spec"),
                "name": .string("Feature spec (living)"),
                "description": .string("The feature's evolving spec/brief. Always reference this; append discovered constraints via findings."),
                "mimeType": .string("text/markdown"),
            ]),
            .object([
                "uri": .string("atelier://feature/\(fid)/brief"),
                "name": .string("Feature brief (living)"),
                "description": .string("The living brief.md — same document as the spec."),
                "mimeType": .string("text/markdown"),
            ]),
        ]
    }

    // MARK: Dispatch

    /// Handles one request. Returns nil for notifications (no response emitted).
    public func handle(_ request: JSONRPCRequest, bridge: any MCPBridge) async -> JSONRPCResponse? {
        if request.isNotification {
            return nil  // e.g. notifications/initialized
        }
        let id = request.id
        switch request.method {
        case "initialize":
            return .success(id: id, result: initializeResult(params: request.params))
        case "tools/list":
            return .success(id: id, result: .object(["tools": .array(tools.map(\.json))]))
        case "tools/call":
            return await handleToolCall(id: id, params: request.params, bridge: bridge)
        case "resources/list":
            return .success(id: id, result: .object(["resources": .array(resources)]))
        case "resources/read":
            return await handleResourceRead(id: id, params: request.params, bridge: bridge)
        case "prompts/list":
            return .success(id: id, result: .object(["prompts": .array([])]))
        default:
            return .failure(id: id, error: .methodNotFound(request.method))
        }
    }

    private func initializeResult(params: JSONValue?) -> JSONValue {
        // Negotiate: honour the client's requested version only if we support it,
        // otherwise fall back to our default (don't blindly echo an unknown one).
        let requested = params?["protocolVersion"]?.stringValue
        let proto = (requested.map(Self.supportedProtocolVersions.contains) ?? false) ? requested! : Self.defaultProtocolVersion
        return .object([
            "protocolVersion": .string(proto),
            "capabilities": .object([
                "tools": .object([:]),
                "resources": .object([:]),
                "prompts": .object([:]),   // prompts/list answered (empty until Phase 4)
            ]),
            "serverInfo": .object([
                "name": .string(context.serverName),
                "version": .string(context.serverVersion),
            ]),
        ])
    }

    // MARK: tools/call

    private func handleToolCall(id: JSONRPCID?, params: JSONValue?, bridge: any MCPBridge) async -> JSONRPCResponse? {
        guard let name = params?["name"]?.stringValue else {
            return .failure(id: id, error: .invalidParams("missing tool name"))
        }
        let arguments = params?["arguments"] ?? .object([:])
        switch name {
        case "task_report_progress":
            return await reportProgress(id: id, arguments: arguments, bridge: bridge)
        default:
            return .failure(id: id, error: .invalidParams("unknown tool: \(name)"))
        }
    }

    private func reportProgress(id: JSONRPCID?, arguments: JSONValue, bridge: any MCPBridge) async -> JSONRPCResponse? {
        guard let pct = arguments["pct"]?.intValue else {
            return .success(id: id, result: Self.toolError("`pct` is required and must be an integer 0–100."))
        }
        let clamped = max(0, min(100, pct))
        let taskId = arguments["taskId"]?.stringValue ?? context.taskId
        guard let taskId, !taskId.isEmpty else {
            return .success(id: id, result: Self.toolError("no taskId provided and no task in scope."))
        }
        var args: [String: JSONValue] = ["pct": .int(clamped)]
        if let note = arguments["note"]?.stringValue { args["note"] = .string(note) }
        let resp = await bridge.send(BridgeRequest(
            id: UUID().uuidString, op: "task_report_progress",
            featureId: context.featureId, taskId: taskId, args: .object(args)
        ))
        if resp.ok {
            return .success(id: id, result: Self.toolText("Progress \(clamped)% recorded for \(taskId)."))
        } else {
            return .success(id: id, result: Self.toolError(resp.error ?? "app unavailable"))
        }
    }

    // MARK: resources/read

    private func handleResourceRead(id: JSONRPCID?, params: JSONValue?, bridge: any MCPBridge) async -> JSONRPCResponse? {
        guard let uri = params?["uri"]?.stringValue else {
            return .failure(id: id, error: .invalidParams("missing uri"))
        }
        let resp = await bridge.send(BridgeRequest(
            id: UUID().uuidString, op: "resource_read",
            featureId: context.featureId, taskId: context.taskId,
            args: .object(["uri": .string(uri)])
        ))
        guard resp.ok else {
            return .failure(id: id, error: .internalError(resp.error ?? "resource unavailable"))
        }
        let text = resp.result?["text"]?.stringValue ?? ""
        let mime = resp.result?["mimeType"]?.stringValue ?? "text/markdown"
        return .success(id: id, result: .object([
            "contents": .array([
                .object(["uri": .string(uri), "mimeType": .string(mime), "text": .string(text)])
            ])
        ]))
    }

    // MARK: MCP content helpers

    static func toolText(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(false)])
    }
    static func toolError(_ text: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(true)])
    }
}
