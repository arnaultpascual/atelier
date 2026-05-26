// SPDX-License-Identifier: MIT
import Foundation
import Observation

/// Owns the form-state of the main UI and the lifecycle of a single spawn.
///
/// Phase 0 supports one spawn at a time. Phase 1 will replace this with a multi-agent
/// `AgentManagerActor` keyed by agent ID, but the UI shape stays the same.
@MainActor
@Observable
final class Orchestrator {
    var apiKey: String = ""
    var prompt: String = "Echo back the words: hello atelier"
    var selectedModelId: String = "claude-sonnet-4-6"
    var includePartialMessages: Bool = false
    var isSpawnInFlight: Bool = false
    var claudePathResolved: String? = ClaudeLocator.locate()
    var workingDirectory: String = NSHomeDirectory()   // user picks via folder dialog

    /// Quick Spawn shares the app-wide model list (`ModelRouter.Model`) instead of a private one.
    /// Opus 4.7's tokenizer note is the single model caveat worth surfacing here.
    var selectedModelWarning: String? {
        selectedModelId == "claude-opus-4-7"
            ? "New tokenizer — Anthropic reports ~1.0×–1.35× more tokens vs Opus 4.6 for the same text."
            : nil
    }

    func canSpawn(server: ApprovalServer) -> Bool {
        guard !isSpawnInFlight, claudePathResolved != nil else { return false }
        guard MCPConfig.helperPath() != nil else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    func spawn(state: AgentState, server: ApprovalServer) async {
        guard !isSpawnInFlight else { return }

        // Three valid auth modes, in priority order:
        //   1. API key typed in the UI (this orchestrator's apiKey field)
        //   2. Keychain (Settings → Authentication tab)
        //   3. ANTHROPIC_API_KEY env var inherited from the launching env
        //   4. Empty → defer to claude CLI's stored OAuth creds (Pro/Max/Enterprise)
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String = trimmed.isEmpty ? APIKeyResolver.resolve() : trimmed

        isSpawnInFlight = true
        state.reset()

        let agentId = UUID()
        let configURL: URL
        do {
            configURL = try MCPConfig.writeTemporaryConfig(
                serverName: server.serverName,
                agentId: agentId,
                socketPath: nil    // 1.3a: helper auto-allows; 1.3b adds the UI socket
            )
        } catch {
            state.markFailed("Could not write MCP config: \(error.localizedDescription)")
            isSpawnInFlight = false
            return
        }

        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: prompt,
            model: selectedModelId,
            apiKey: resolvedKey,
            agentId: agentId,
            settingsPath: configURL.path,
            workingDirectory: workingDirectory,
            additionalDirs: [],
            includePartialMessages: includePartialMessages,
            maxTurns: 20,
            resumeSessionId: nil
        )

        let eventSink: @Sendable (StreamEvent) async -> Void = { event in
            await MainActor.run {
                state.ingest(event)
            }
        }
        let stderrSink: @Sendable (String) async -> Void = { line in
            await MainActor.run {
                state.appendStderr(line)
            }
        }

        do {
            try await runner.run(invocation: invocation, onEvent: eventSink, onStderr: stderrSink)
        } catch {
            if state.status != .completed {
                state.markFailed(error.localizedDescription)
            }
        }

        MCPConfig.cleanup(configURL)
        isSpawnInFlight = false
    }
}
