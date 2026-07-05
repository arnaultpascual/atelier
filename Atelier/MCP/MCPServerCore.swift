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
        "task_update_status", "task_signal_blocked",
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
            .object([
                "uri": .string("atelier://feature/\(fid)/attachments"),
                "name": .string("Feature shared files"),
                "description": .string("Files the user shared with the brief (mockups, specs, screenshots): names + paths — Read the paths to view them."),
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

    // These mirror Atelier's real AIAssistant/PreparePromptView prompts (same
    // instructional spine + JSON schema), assembled from arguments so they stay
    // self-contained (no app round-trip). Kept faithful to the shipped prompts.
    static let prompts: [PromptDef] = [
        PromptDef(
            name: "atelier_decompose",
            description: "Decompose a feature brief into self-contained, single-worker-sized, conflict-minimal, dependency-explicit task drafts (Atelier's Opus decomposer).",
            arguments: [
                PromptArg(name: "brief", description: "The feature brief.", required: true, defaultValue: ""),
                PromptArg(name: "project_name", description: "Project name.", required: false, defaultValue: "this project"),
                PromptArg(name: "profile_name", description: "Project profile/mode name.", required: false, defaultValue: "generic"),
                PromptArg(name: "profile_id", description: "Project profile/mode id.", required: false, defaultValue: "generic"),
                PromptArg(name: "default_model", description: "Project default model.", required: false, defaultValue: "claude-sonnet-4-6"),
                PromptArg(name: "existing_titles", description: "Existing task titles to avoid duplicating.", required: false, defaultValue: "(none yet)"),
            ],
            template: """
            You are the task decomposer for Atelier, a macOS IDE that orchestrates Claude Code workers.

            HOW YOUR OUTPUT IS EXECUTED — this changes everything:
            - Each task you emit is handed to a SEPARATE Claude Code worker.
            - Each worker runs in its OWN git worktree, in parallel with the others.
            - A worker sees ONLY its own task description — NOT this brief, NOT the other tasks, NOT this conversation. If a fact isn't in the task's own description, the worker does not have it.
            - Worktrees merge back independently, so two tasks that edit the SAME file collide on merge.

            Therefore every task MUST be:
            1. SELF-CONTAINED — restate every relevant fact, name, value, shape and decision the worker needs. Never write "as above" or "see the brief".
            2. SINGLE-WORKER-SIZED — one focused ~1-PR change finishable in a single spawn. Split bigger work.
            3. CONFLICT-MINIMAL — partition along file/module boundaries; state each task's file area AND what it must NOT touch (owned by siblings).
            4. DEPENDENCY-EXPLICIT — declare depends_on where a task needs another's output; think in EXECUTION WAVES and maximise parallelism (a dependency only when genuinely needed).

            Project: {{project_name}}
            Profile: {{profile_name}} ({{profile_id}})
            Project default model: {{default_model}}
            Existing task titles (don't duplicate):
            {{existing_titles}}

            Brief:
            \"\"\"
            {{brief}}
            \"\"\"

            For EACH task, the `description` IS the worker's entire brief. Write it as tight markdown with these sections (drop one only if genuinely empty):
            ## Goal — one sentence: the outcome.
            ## Context — self-contained background: relevant facts, data shapes, names, endpoints, constraints.
            ## Steps — numbered, concrete, in order.
            ## Files — specific files/dirs to create or edit, then a "Do not touch:" line naming sibling-owned areas.
            ## Acceptance criteria — testable bullets defining "done" (commands to run, behaviour to observe).

            Output ONLY this JSON object — no preamble, no fences:
            {
              "tasks": [
                {"id":"t1","title":"...","description":"## Goal\\n...","priority":"medium","labels":["..."],"depends_on":[],"suggested_model":"claude-sonnet-4-6"}
              ]
            }
            Aim for 3–12 tasks. Prefer more small self-contained tasks over few big ones — small tasks parallelise and merge cleanly.
            """),
        PromptDef(
            name: "atelier_refine_brief",
            description: "Critique + resolve + rewrite the consolidated feature brief toward a complete, objectively-testable spec, then emit the convergence trailer.",
            arguments: [
                PromptArg(name: "current", description: "Current distilled brief (empty for the first pass).", required: false, defaultValue: ""),
                PromptArg(name: "coverage", description: "Optional coverage aim clause, e.g. ' and a coverage AIM of ≥ 90%'.", required: false, defaultValue: ""),
                PromptArg(name: "sentinel", description: "Machine convergence trailer sentinel.", required: false, defaultValue: "<<ATELIER-REFINE>>"),
            ],
            template: """
            Refinement pass. Re-ground on the ORIGINAL request and ALL context above, then improve the brief.

            Current distilled brief to critique and improve (if empty, produce the first consolidated version):
            \"\"\"
            {{current}}
            \"\"\"

            Do, in order:
            1. CRITIQUE: find the open questions, gaps, ambiguities, and any acceptance criteria that aren't objectively testable.
            2. RESOLVE: answer each by making the most reasonable assumption given the original request and pinned context — and STATE those assumptions explicitly. Keep an item as an OPEN QUESTION only if it genuinely needs the human and would change the implementation.
            3. REWRITE the single consolidated brief as clean markdown (no fences) with these sections, dropping none:
            ## Goal — one sentence outcome.
            ## Context — self-contained background + the assumptions you made this pass.
            ## Constraints — hard requirements, non-goals, what not to touch.
            ## Acceptance criteria — objectively TESTABLE bullets. Strict TDD: each verifiable by a test written first that then passes{{coverage}}.
            ## Open questions — genuinely-blocking questions for the human, or "None".

            Then, on a NEW LINE after the brief, output EXACTLY this trailer (no fences, nothing after it):
            {{sentinel}}
            {"open_questions": ["..."], "materially_changed": true|false, "stable": true|false}
            """),
        PromptDef(
            name: "atelier_review",
            description: "Review a completed worker's worktree against the base branch and classify every issue by severity (Atelier's Opus reviewer).",
            arguments: [
                PromptArg(name: "task_title", description: "Task title.", required: true, defaultValue: ""),
                PromptArg(name: "task_description", description: "Task brief/description.", required: false, defaultValue: "(no description)"),
                PromptArg(name: "base_branch", description: "Base branch to diff against.", required: false, defaultValue: "main"),
            ],
            template: """
            You are reviewing a feature branch a worker just completed, checked out in the current directory (its git worktree). The task it was given:

            Title: {{task_title}}
            Brief:
            \"\"\"
            {{task_description}}
            \"\"\"

            Inspect the ACTUAL change: run `git diff {{base_branch}}...HEAD` and read changed files as needed to see exactly what changed vs the base branch. Judge whether it correctly and completely does what the task asked, and whether it's safe to merge.

            Classify EVERY issue by severity:
            - critical: wrong behavior, crash, data loss, security hole, or a broken build/tests.
            - major: a stated acceptance criterion unmet, a real edge-case bug, a meaningful perf regression, or required tests missing.
            - minor: style, naming, small non-functional improvements.
            - cosmetic: formatting / whitespace / comment phrasing.

            Output ONLY this JSON object — no prose, no fences:
            {
              "verdict": "APPROVE | CHANGES_REQUESTED | NEEDS_DISCUSSION",
              "summary": "1-3 sentence overall assessment",
              "findings": [
                {"severity":"critical","file":"path/file.swift","line":42,"summary":"what is wrong","suggested_fix":"what to change"}
              ]
            }
            Use [] for findings when the change is clean. Quote REAL file paths/lines from the diff.
            """),
        PromptDef(
            name: "atelier_synthesize_feature",
            description: "Write the FINAL synthesis for a fully-merged feature: judge the whole feature against the demand and split behavior into machine-guaranteed vs human-verified.",
            arguments: [
                PromptArg(name: "demand", description: "The feature demand (union of merged tasks' briefs).", required: true, defaultValue: "(no briefs)"),
                PromptArg(name: "acceptance_criteria", description: "Aggregated acceptance criteria (verbatim, one per line).", required: false, defaultValue: "(none stated)"),
                PromptArg(name: "changed_files", description: "Changed files.", required: false, defaultValue: "(none)"),
                PromptArg(name: "test_summary", description: "Integration test suite summary.", required: false, defaultValue: "(not run)"),
                PromptArg(name: "coverage", description: "Coverage summary.", required: false, defaultValue: "not measured"),
                PromptArg(name: "base_branch", description: "Base branch to diff against.", required: false, defaultValue: "main"),
                PromptArg(name: "build_status", description: "Build status.", required: false, defaultValue: "n/a"),
                PromptArg(name: "review_rollup", description: "Per-task review rollup.", required: false, defaultValue: "(none)"),
            ],
            template: """
            You are writing the FINAL synthesis for a feature an autopilot just built across several tasks, all merged into the integration branch checked out in the current directory. Judge the WHOLE feature against the demand, and split user-visible behavior into what's already guaranteed by code/tests vs. what a human must verify by hand.

            Inspect the ACTUAL integrated change: run `git diff {{base_branch}}...HEAD` and read the changed files, so your judgments describe the REAL behavior — not boilerplate.

            THE FEATURE DEMAND (union of the merged tasks' briefs):
            \"\"\"
            {{demand}}
            \"\"\"
            Aggregated acceptance criteria (verbatim):
            {{acceptance_criteria}}

            WHAT THE MACHINE ALREADY VERIFIED (facts — do not contradict):
            - Integration test suite: {{test_summary}}
            - Coverage: {{coverage}}
            - Build: {{build_status}}
            - Changed files: {{changed_files}}
            - Per-task review rollup: {{review_rollup}}

            Output ONLY this JSON object — no prose, no fences:
            {
              "feature_title": "<= 8 words naming the feature",
              "summary": "one paragraph: what was implemented across the tasks, in plain technical language",
              "answers_the_demand": true,
              "conformity_rationale": "1-3 sentences: does the integrated work satisfy the demand? what, if anything, is missing",
              "gaps": ["any required aspect of the demand not (fully) met — empty if fully met"],
              "criteria": [{"text":"<verbatim criterion>","coverage":"automated|partial|manual","evidence":"which test guarantees it, or why only a human can judge it"}],
              "manual_checks": [{"category":"ui|device|integration|visual|performance|accessibility|security|edgeCase|dataMigration","title":"behavior a human must exercise","how_to":"numbered steps in the running app","why":"why code/tests can't guarantee this"}]
            }
            manual_checks = the FEATURE recette: keep only what code/tests cannot guarantee (perceptual, interactive, real-device, performance, accessibility, end-to-end). EXCLUDE anything a passing test or the type system already guarantees.
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
