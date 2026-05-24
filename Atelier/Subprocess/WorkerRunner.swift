// SPDX-License-Identifier: MIT
import Foundation
import Subprocess
import System
import os

/// Spawns a `claude -p --output-format stream-json` worker via `swift-subprocess` and
/// emits each NDJSON event line through an `AsyncStream`.
///
/// Each `WorkerRunner` drives one `claude` subprocess to completion in a given working
/// directory; callers (TaskSpawner, ChatSpawner, Quick Spawn) own concurrency and worktree
/// setup. Cancelling the enclosing `Task` sends SIGTERM via swift-subprocess's cooperative
/// cancellation.
actor WorkerRunner {
    enum Error: Swift.Error, LocalizedError {
        case claudeNotFound
        case workingDirectoryInvalid(String)
        case spawnFailed(underlying: Swift.Error)
        case nonZeroExit(code: Int32, stderrTail: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Could not find the `claude` executable. Install Claude Code and ensure it's at one of the expected paths."
            case .workingDirectoryInvalid(let path):
                return "Working directory does not exist or is not a directory: \(path)"
            case .spawnFailed(let err):
                return "Failed to spawn claude: \(err.localizedDescription)"
            case .nonZeroExit(let code, let tail):
                if tail.isEmpty {
                    return "Worker exited with code \(code) (no stderr captured)"
                }
                return "Worker exited with code \(code). stderr: \(tail)"
            }
        }
    }

    struct Invocation: Sendable {
        let prompt: String
        let model: String
        /// Empty → don't override `ANTHROPIC_API_KEY`; the `claude` CLI falls back to
        /// its own stored OAuth credentials (Pro / Max / Max x20 / Enterprise subscription
        /// flow via `claude auth`). Non-empty → set the env var, which takes precedence.
        let apiKey: String
        let agentId: UUID
        /// Settings JSON file written by `MCPConfig`. Contains a PreToolUse hook
        /// pointing at the AtelierApprovalHelper binary.
        let settingsPath: String
        let workingDirectory: String     // absolute path the worker runs in
        let additionalDirs: [String]     // extra dirs for `claude --add-dir` (e.g. attachments)
        let includePartialMessages: Bool
        let maxTurns: Int
        /// When non-nil, the worker re-attaches to a previous claude session via
        /// `--resume <id>`. Used by the Iterate flow.
        let resumeSessionId: String?
        /// Chat-only opt-ins: when set, the corresponding tools are removed from
        /// the chat's `--disallowed-tools` list (web search / file reads).
        var chatAllowWeb: Bool = false
        var chatAllowFiles: Bool = false
        /// When non-nil, the prompt is sent as a stream-json user event on stdin
        /// (with `--input-format stream-json`) instead of as an argv positional —
        /// required to pass image content blocks. stdin is kept open until the
        /// terminal `result` event. Default nil → unchanged argv behaviour.
        var inputStreamJSON: String? = nil
    }

    private let logger = Logger(subsystem: "app.atelier", category: "worker")
    private let lineDecoder = NDJSONLineDecoder()

    /// Runs the worker. Emits decoded `StreamEvent` values into `onEvent` and raw stderr
    /// lines into `onStderr`. Returns when the worker exits. Throws on spawn failure or
    /// non-zero exit (with the tail of stderr embedded in the error message).
    func run(
        invocation: Invocation,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void,
        onStderr: @escaping @Sendable (String) async -> Void
    ) async throws {
        try await execute(invocation: invocation, mode: .gated, onEvent: onEvent, onStderr: onStderr)
    }

    /// Runs the worker WITHOUT routing through the approval hook. Uses
    /// `--permission-mode bypassPermissions` instead of `--settings`. Reserved
    /// for read-only orchestrator tasks like the worktree review where we
    /// don't want the user gating every Read/Grep call.
    func runUngated(
        invocation: Invocation,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void,
        onStderr: @escaping @Sendable (String) async -> Void
    ) async throws {
        try await execute(invocation: invocation, mode: .ungated, onEvent: onEvent, onStderr: onStderr)
    }

    /// Runs claude as a pure conversation: no tools (`--disallowed-tools` set
    /// to every standard tool), no approval hook, no agentic loop. Used by
    /// the Chat feature where the user wants a chat-style exchange, not a
    /// worker.
    func runChat(
        invocation: Invocation,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void,
        onStderr: @escaping @Sendable (String) async -> Void
    ) async throws {
        try await execute(invocation: invocation, mode: .chat, onEvent: onEvent, onStderr: onStderr)
    }

    private enum ExecutionMode {
        case gated      // approval hook on (default for task workers)
        case ungated    // bypass permissions, all tools available (review)
        case chat       // bypass permissions, ALL tools disallowed (chat)
    }

    private func execute(
        invocation: Invocation,
        mode: ExecutionMode,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void,
        onStderr: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard let claudePath = ClaudeLocator.locate() else {
            throw Error.claudeNotFound
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: invocation.workingDirectory, isDirectory: &isDir),
              isDir.boolValue else {
            throw Error.workingDirectoryInvalid(invocation.workingDirectory)
        }

        let debugLogPath = NSTemporaryDirectory() + "atelier-claude-\(invocation.agentId.uuidString).log"

        var arguments: [String] = [
            "-p",
            "--debug-file", debugLogPath,
            "--output-format", "stream-json",
            "--verbose",
            "--model", invocation.model,
            "--max-turns", String(invocation.maxTurns)
        ]
        switch mode {
        case .gated:
            arguments.append(contentsOf: ["--settings", invocation.settingsPath])
        case .ungated:
            arguments.append(contentsOf: ["--permission-mode", "bypassPermissions"])
        case .chat:
            // Pure conversation by default — no tools, no approval flow. Capability
            // opt-ins selectively re-enable web search and/or file reads.
            arguments.append(contentsOf: ["--permission-mode", "bypassPermissions"])
            var disallowed = [
                "Write", "Edit", "NotebookEdit", "Bash",
                "TodoWrite", "Agent", "ToolSearch"
            ]
            if !invocation.chatAllowFiles { disallowed += ["Read", "Glob", "Grep"] }
            if !invocation.chatAllowWeb { disallowed += ["WebFetch", "WebSearch"] }
            arguments.append("--disallowed-tools")
            arguments.append(contentsOf: disallowed)
        }
        if let resumeId = invocation.resumeSessionId, !resumeId.isEmpty {
            arguments.append(contentsOf: ["--resume", resumeId])
        }
        if invocation.includePartialMessages {
            arguments.append("--include-partial-messages")
        }
        // `--add-dir <dirs…>` is a *variadic* flag in commander.js: it greedily
        // consumes following positional args until the next `--option` or `--`.
        // Pass all dirs together under a single flag and terminate with `--`
        // so the trailing `<prompt>` isn't slurped as another directory.
        if !invocation.additionalDirs.isEmpty {
            arguments.append("--add-dir")
            arguments.append(contentsOf: invocation.additionalDirs)
        }
        if invocation.inputStreamJSON != nil {
            // Prompt (with image blocks) is delivered as a stream-json user event
            // on stdin; don't also pass it as an argv positional.
            arguments.append(contentsOf: ["--input-format", "stream-json"])
        } else {
            arguments.append("--")
            arguments.append(invocation.prompt)
        }
        logger.info("claude debug log → \(debugLogPath, privacy: .public)")

        var envOverrides: [Environment.Key: String?] = [
            "ATELIER_AGENT_ID": invocation.agentId.uuidString
        ]
        if !invocation.apiKey.isEmpty {
            envOverrides["ANTHROPIC_API_KEY"] = invocation.apiKey
        }
        let environment: Environment = .inherit.updating(envOverrides)

        logger.info("Spawning claude at \(claudePath, privacy: .public) model=\(invocation.model, privacy: .public) cwd=\(invocation.workingDirectory, privacy: .public)")

        let decoder = lineDecoder
        let log = logger
        // Box mutable stderr buffer in an actor-safe collector.
        let stderrCollector = StderrCollector()
        let inputPayload = invocation.inputStreamJSON.map { $0 + "\n" }

        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(claudePath)),
                arguments: Arguments(arguments),
                environment: environment,
                workingDirectory: FilePath(invocation.workingDirectory),
                body: { execution, inputWriter, stdout, stderr in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        if let payload = inputPayload {
                            // stream-json input: write the user event (concurrently, to
                            // avoid a pipe deadlock on big image payloads) and keep stdin
                            // OPEN until the terminal `result` lands — closing early makes
                            // claude drop the turn and emit nothing.
                            group.addTask { _ = try? await inputWriter.write(payload) }
                        } else {
                            // claude -p hangs waiting on a non-TTY stdin pipe; close it.
                            try await inputWriter.finish()
                        }
                        group.addTask {
                            // Lift the default 128 KB line cap — a Read tool_result
                            // (file contents) arrives as one big JSONL line.
                            for try await line in stdout.lines(encoding: UTF8.self,
                                                               bufferingPolicy: .maxLineLength(16 * 1024 * 1024)) {
                                if let event = decoder.decode(line) {
                                    await onEvent(event)
                                    if inputPayload != nil, case .result = event.kind {
                                        try? await inputWriter.finish()
                                    }
                                }
                            }
                        }
                        group.addTask {
                            for try await line in stderr.lines() {
                                await stderrCollector.append(line)
                                await onStderr(line)
                                log.debug("worker stderr: \(line, privacy: .public)")
                            }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            let status = outcome.terminationStatus
            switch status {
            case .exited(let code):
                if code != 0 {
                    let tail = await stderrCollector.tail()
                    log.error("Worker exited code=\(code) stderr=\(tail, privacy: .public)")
                    throw Error.nonZeroExit(code: Int32(code), stderrTail: tail)
                }
            case .signaled(let signal):
                let tail = await stderrCollector.tail()
                log.error("Worker terminated by signal \(signal) stderr=\(tail, privacy: .public)")
                throw Error.nonZeroExit(code: Int32(signal), stderrTail: tail)
            }
        } catch let err as Error {
            throw err
        } catch {
            throw Error.spawnFailed(underlying: error)
        }
    }
}

private actor StderrCollector {
    private var buffer: [String] = []
    private let cap = 200

    func append(_ line: String) {
        buffer.append(line)
        if buffer.count > cap { buffer.removeFirst(buffer.count - cap) }
    }

    func tail(_ lines: Int = 20) -> String {
        let take = buffer.suffix(lines)
        return take.joined(separator: "\n")
    }
}
