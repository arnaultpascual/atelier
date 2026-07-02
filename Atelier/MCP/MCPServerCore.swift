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

    // MARK: schema helpers
    static func strProp(_ desc: String) -> JSONValue { .object(["type": .string("string"), "description": .string(desc)]) }
    static func intProp(_ desc: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(desc)]) }
    static func schema(_ props: KeyValuePairs<String, JSONValue>, required: [String]) -> JSONValue {
        var p: [String: JSONValue] = [:]
        for (k, v) in props { p[k] = v }
        return .object(["type": .string("object"), "properties": .object(p), "required": .array(required.map(JSONValue.string))])
    }

    /// Tool names that are simple bridge-forwarding mutations (args passed through
    /// to the app-side handler, which returns ok/fail). Feature-scoped.
    static let forwardingMutationTools: Set<String> = [
        "brief_set_overview", "brief_append_section", "brief_add_requirement",
        "brief_add_acceptance_criterion", "brief_add_open_question", "brief_resolve_open_question",
        "brief_record_decision", "brief_attach_reference", "spec_record_finding",
        "task_update_status", "task_signal_blocked", "wave_mark_done",
        "test_report_run", "review_request",
    ]

    /// Tools that return data from the app (rendered back as tool text).
    static let queryTools: Set<String> = [
        "task_get_dependencies", "plan_next_wave", "coverage_get", "coverage_uncovered",
    ]

    var tools: [ToolDef] {
        [
            ToolDef(name: "task_report_progress",
                description: "Report live build progress for a task so it shows in Atelier's kanban. Call periodically as you work (0–100).",
                inputSchema: Self.schema([
                    "taskId": Self.strProp("Task id; defaults to the current task if omitted."),
                    "pct": Self.intProp("Percent complete, 0–100."),
                    "note": Self.strProp("Optional short status note."),
                ], required: ["pct"])),

            // --- brief building (Phase 2) ---
            ToolDef(name: "brief_set_overview",
                description: "Set/replace the Overview section of the living feature brief.",
                inputSchema: Self.schema(["markdown": Self.strProp("Overview markdown.")], required: ["markdown"])),
            ToolDef(name: "brief_append_section",
                description: "Append a free-form section to the living brief.",
                inputSchema: Self.schema([
                    "heading": Self.strProp("Section heading."),
                    "markdown": Self.strProp("Section body markdown."),
                ], required: ["heading", "markdown"])),
            ToolDef(name: "brief_add_requirement",
                description: "Add a requirement bullet to the brief.",
                inputSchema: Self.schema([
                    "text": Self.strProp("Requirement text."),
                    "priority": Self.strProp("Optional priority (e.g. high/medium/low)."),
                ], required: ["text"])),
            ToolDef(name: "brief_add_acceptance_criterion",
                description: "Add an acceptance criterion (checkbox) to the brief.",
                inputSchema: Self.schema(["text": Self.strProp("Acceptance criterion.")], required: ["text"])),
            ToolDef(name: "brief_add_open_question",
                description: "Record an open question in the brief.",
                inputSchema: Self.schema(["text": Self.strProp("The open question.")], required: ["text"])),
            ToolDef(name: "brief_resolve_open_question",
                description: "Resolve the Nth (1-based) open question with an answer.",
                inputSchema: Self.schema([
                    "index": Self.intProp("1-based index of the open question."),
                    "answer": Self.strProp("The answer."),
                ], required: ["index", "answer"])),
            ToolDef(name: "brief_record_decision",
                description: "Record a decision + rationale in the brief.",
                inputSchema: Self.schema([
                    "decision": Self.strProp("The decision."),
                    "rationale": Self.strProp("Why."),
                ], required: ["decision", "rationale"])),
            ToolDef(name: "brief_attach_reference",
                description: "Attach a reference (URL or path) to the brief.",
                inputSchema: Self.schema([
                    "urlOrPath": Self.strProp("URL or file path."),
                    "note": Self.strProp("Optional note."),
                ], required: ["urlOrPath"])),
            ToolDef(name: "spec_record_finding",
                description: "Record a discovered constraint + workaround so other feature workers and reviewers see it. Use when something in the spec turns out impossible/limited and you worked around it.",
                inputSchema: Self.schema([
                    "finding": Self.strProp("What you discovered (e.g. an API limitation)."),
                    "impact": Self.strProp("Optional impact on the spec."),
                    "workaround": Self.strProp("Optional workaround you applied."),
                ], required: ["finding"])),

            // --- tasks / waves / coverage / tests / review (Phase 3) ---
            ToolDef(name: "task_update_status",
                description: "Set a task's status atomically (To Do / In Progress / Review / Blocked). Keeps the backlog .md and DB in sync. Done is NOT settable here — it follows a successful merge; use Review when ready.",
                inputSchema: Self.schema([
                    "taskId": Self.strProp("Task id; defaults to the current task."),
                    "status": Self.strProp("One of: To Do, In Progress, Review, Blocked."),
                ], required: ["status"])),
            ToolDef(name: "task_signal_blocked",
                description: "Mark the current task blocked and surface the reason to the human immediately.",
                inputSchema: Self.schema([
                    "taskId": Self.strProp("Task id; defaults to the current task."),
                    "reason": Self.strProp("Why it's blocked."),
                    "needs": Self.strProp("Optional: what would unblock it."),
                ], required: ["reason"])),
            ToolDef(name: "task_get_dependencies",
                description: "List tasks the given task depends on and whether they're done (are you runnable now?).",
                inputSchema: Self.schema(["taskId": Self.strProp("Task id; defaults to the current task.")], required: [])),
            ToolDef(name: "wave_mark_done",
                description: "Advisory signal that the current dependency wave is complete. The next wave is derived automatically from task statuses — call plan_next_wave to see what's runnable.",
                inputSchema: Self.schema(["wave": Self.intProp("Wave/round number just completed.")], required: [])),
            ToolDef(name: "plan_next_wave",
                description: "Ask which feature tasks are runnable now (the next wave).",
                inputSchema: Self.schema([:], required: [])),
            ToolDef(name: "coverage_get",
                description: "Get a summary of current test coverage vs the soft 90% target for this feature (reads the newest coverage report in your worktree; run tests with coverage first).",
                inputSchema: Self.schema([:], required: [])),
            ToolDef(name: "coverage_uncovered",
                description: "List files/areas below the coverage target, to guide where to add tests.",
                inputSchema: Self.schema([:], required: [])),
            ToolDef(name: "test_report_run",
                description: "Report a structured test run (ADVISORY — recorded as a summary; it does NOT flip the deterministic merge gate, which Atelier runs itself).",
                inputSchema: Self.schema([
                    "passed": Self.intProp("Number of passing tests."),
                    "failed": Self.intProp("Number of failing tests."),
                    "skipped": Self.intProp("Number of skipped tests."),
                    "coveragePct": Self.intProp("Optional coverage percent."),
                ], required: ["passed", "failed"])),
            ToolDef(name: "review_request",
                description: "Request a code review of the current task's worktree (the /code-review gate).",
                inputSchema: Self.schema(["taskId": Self.strProp("Task id; defaults to the current task.")], required: [])),
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

    // MARK: Prompts (Phase 4 — self-contained static templates)

    struct PromptArg: Sendable { let name: String; let description: String; let required: Bool; let defaultValue: String }
    struct PromptDef: Sendable {
        let name: String
        let description: String
        let arguments: [PromptArg]
        let template: String
        var listJSON: JSONValue {
            .object([
                "name": .string(name),
                "description": .string(description),
                "arguments": .array(arguments.map {
                    .object(["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)])
                }),
            ])
        }
        /// Substitutes {{arg}} placeholders with provided args (or defaults).
        func render(_ args: [String: JSONValue]) -> String {
            var out = template
            for a in arguments {
                let val = args[a.name]?.stringValue ?? a.defaultValue
                out = out.replacingOccurrences(of: "{{\(a.name)}}", with: val)
            }
            return out
        }
    }

    static let prompts: [PromptDef] = [
        PromptDef(
            name: "atelier_decompose",
            description: "Decompose a feature brief into self-contained, single-worker TDD tasks.",
            arguments: [
                PromptArg(name: "brief", description: "The feature brief.", required: true, defaultValue: ""),
                PromptArg(name: "project_name", description: "Project name.", required: false, defaultValue: "this project"),
                PromptArg(name: "profile_name", description: "Project profile/mode.", required: false, defaultValue: "generic"),
                PromptArg(name: "existing_titles", description: "Existing task titles to avoid duplicating.", required: false, defaultValue: "(none yet)"),
            ],
            template: """
            You are Atelier's task decomposer. Break the feature brief into a JSON array of self-contained, single-worker-sized task drafts.

            FEATURE BRIEF:
            {{brief}}

            PROJECT: {{project_name}} (profile: {{profile_name}})
            EXISTING TASK TITLES (avoid duplicates): {{existing_titles}}

            Rules:
            - Each task must be independently buildable by one worker via strict TDD (tests first).
            - Prefer 3–8 tasks, each with a clear, testable outcome.
            - Declare dependencies by task ref where ordering matters.
            - Always reference the original brief/spec; never invent scope.

            Return ONLY a JSON array; each element: {"ref","title","descriptionMd","priority","dependsOnRefs":[]}.
            """),
        PromptDef(
            name: "atelier_refine_brief",
            description: "Refine the living feature brief toward a complete, testable spec.",
            arguments: [
                PromptArg(name: "current", description: "Current brief.md contents.", required: true, defaultValue: ""),
                PromptArg(name: "input", description: "New input to incorporate.", required: false, defaultValue: ""),
                PromptArg(name: "sentinel", description: "Convergence trailer.", required: false, defaultValue: "<<BRIEF-STABLE>>"),
            ],
            template: """
            Refine this living feature brief. Incorporate the new input and rewrite the brief so it is complete, unambiguous, and testable.

            CURRENT BRIEF:
            {{current}}

            NEW INPUT:
            {{input}}

            Keep the canonical sections (Overview, Requirements, Acceptance Criteria, Open Questions, Decisions, References). Prefer Atelier's structured brief_* MCP tools to edit sections when available. When the brief is stable and needs no more open questions, end your message with the machine trailer: {{sentinel}}
            """),
        PromptDef(
            name: "atelier_review",
            description: "Review a task's worktree changes for correctness then cleanups.",
            arguments: [
                PromptArg(name: "task_title", description: "Task title.", required: true, defaultValue: ""),
                PromptArg(name: "task_description", description: "Task description.", required: false, defaultValue: ""),
                PromptArg(name: "base_branch", description: "Base branch to diff against.", required: false, defaultValue: "main"),
            ],
            template: """
            Review the worktree changes for task “{{task_title}}” against base branch {{base_branch}}.

            TASK:
            {{task_description}}

            Focus on correctness bugs first, then reuse/simplification/efficiency. Verify the tests actually exercise the change and were not weakened. Return a JSON object: {"summary","findings":[{"severity","file","detail"}],"approved":bool}.
            """),
        PromptDef(
            name: "atelier_synthesize_feature",
            description: "Synthesize the feature deliverable and confirm it answers the original demand.",
            arguments: [
                PromptArg(name: "demand", description: "Original demand/spec.", required: true, defaultValue: ""),
                PromptArg(name: "acceptance_criteria", description: "Acceptance criteria.", required: false, defaultValue: ""),
                PromptArg(name: "changed_files", description: "Changed files.", required: false, defaultValue: ""),
                PromptArg(name: "test_summary", description: "Test summary.", required: false, defaultValue: ""),
                PromptArg(name: "coverage", description: "Coverage summary.", required: false, defaultValue: "not measured"),
                PromptArg(name: "coverage_target", description: "Soft coverage target.", required: false, defaultValue: "90"),
                PromptArg(name: "build_status", description: "Build status.", required: false, defaultValue: "n/a"),
            ],
            template: """
            Synthesize the feature deliverable. Confirm the built feature answers the ORIGINAL demand.

            DEMAND:
            {{demand}}

            ACCEPTANCE CRITERIA:
            {{acceptance_criteria}}

            CHANGED FILES:
            {{changed_files}}

            TEST SUMMARY: {{test_summary}}
            COVERAGE: {{coverage}} (soft target {{coverage_target}}%)
            BUILD: {{build_status}}

            Return a JSON object: {"featureTitle","summary","answersTheDemand":bool,"conformityRationale","gaps":[]}.
            """),
    ]

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
            return .success(id: id, result: .object(["prompts": .array(Self.prompts.map(\.listJSON))]))
        case "prompts/get":
            return promptsGet(id: id, params: request.params)
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
        case _ where Self.queryTools.contains(name):
            return await forward(id: id, op: name, arguments: arguments, bridge: bridge, query: true)
        case _ where Self.forwardingMutationTools.contains(name):
            return await forward(id: id, op: name, arguments: arguments, bridge: bridge, query: false)
        default:
            return .failure(id: id, error: .invalidParams("unknown tool: \(name)"))
        }
    }

    /// Forwards a tool call to the app over the bridge. `query` tools render the
    /// app's result as text; mutation tools render an ack. Both degrade to a tool
    /// error (not a JSON-RPC error) so the worker keeps going.
    private func forward(id: JSONRPCID?, op: String, arguments: JSONValue, bridge: any MCPBridge, query: Bool) async -> JSONRPCResponse? {
        guard let featureId = context.featureId else {
            return .success(id: id, result: Self.toolError("no feature in scope for \(op)"))
        }
        let taskId = arguments["taskId"]?.stringValue ?? context.taskId
        let resp = await bridge.send(BridgeRequest(
            id: UUID().uuidString, op: op, featureId: featureId, taskId: taskId, args: arguments))
        guard resp.ok else {
            return .success(id: id, result: Self.toolError(resp.error ?? "app unavailable"))
        }
        if query {
            let text = resp.result?["text"]?.stringValue ?? Self.jsonText(resp.result ?? .null)
            return .success(id: id, result: Self.toolText(text))
        } else {
            let msg = resp.result?["message"]?.stringValue ?? "Done: \(op)."
            return .success(id: id, result: Self.toolText(msg))
        }
    }

    static func jsonText(_ v: JSONValue) -> String {
        (try? MCPCodec.encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func promptsGet(id: JSONRPCID?, params: JSONValue?) -> JSONRPCResponse? {
        guard let name = params?["name"]?.stringValue else {
            return .failure(id: id, error: .invalidParams("missing prompt name"))
        }
        guard let def = Self.prompts.first(where: { $0.name == name }) else {
            return .failure(id: id, error: .invalidParams("unknown prompt: \(name)"))
        }
        let args = params?["arguments"]?.objectValue ?? [:]
        let body = def.render(args)
        return .success(id: id, result: .object([
            "description": .string(def.description),
            "messages": .array([
                .object(["role": .string("user"),
                         "content": .object(["type": .string("text"), "text": .string(body)])]),
            ]),
        ]))
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
