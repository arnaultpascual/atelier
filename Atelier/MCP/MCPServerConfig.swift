// SPDX-License-Identifier: MIT
import Foundation

/// Writes the per-spawn JSON consumed by `claude --mcp-config <path>`, pointing
/// at the embedded `AtelierMCPServer` stdio binary and passing it the Unix
/// socket + feature/task scope.
///
/// Sibling of `MCPConfig` (which writes the `--settings` approval hook). Both
/// files coexist on a spawn: `--settings` (approval hook) AND `--mcp-config`
/// (capability). Verified to compose against claude 2.1.190.
///
/// Config shape:
/// ```json
/// { "mcpServers": { "atelier": {
///     "command": "/…/Atelier.app/Contents/MacOS/AtelierMCPServer",
///     "args": ["--socket","/tmp/at-mcp-….sock","--feature-id","…","--task-id","…",
///              "--project-path","…","--agent-id","…"] } } }
/// ```
enum MCPServerConfig {
    /// Resolves the embedded server binary (copied into Contents/MacOS by a
    /// post-build script, same as the approval helper).
    static func serverPath() -> String? {
        guard let mainExe = Bundle.main.executableURL else { return nil }
        let server = mainExe.deletingLastPathComponent().appendingPathComponent("AtelierMCPServer")
        return FileManager.default.isExecutableFile(atPath: server.path) ? server.path : nil
    }

    static func writeTemporaryConfig(
        serverName: String = "atelier",
        agentId: UUID,
        socketPath: String,
        featureId: String,
        taskId: String?,
        projectPath: String
    ) throws -> URL {
        guard let server = serverPath() else {
            throw NSError(domain: "app.atelier.mcp", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AtelierMCPServer binary not found in app bundle. Re-build the project."
            ])
        }
        let payload = buildConfigPayload(
            serverName: serverName, command: server, socketPath: socketPath,
            featureId: featureId, taskId: taskId, projectPath: projectPath,
            agentId: agentId.uuidString
        )
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-mcp-\(agentId.uuidString).json")
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Pure config-payload builder (unit-tested), independent of Bundle.main.
    /// `--task-id` is omitted when there is no task in scope.
    static func buildConfigPayload(
        serverName: String,
        command: String,
        socketPath: String,
        featureId: String,
        taskId: String?,
        projectPath: String,
        agentId: String
    ) -> [String: Any] {
        var args: [String] = ["--socket", socketPath, "--feature-id", featureId]
        if let taskId, !taskId.isEmpty { args += ["--task-id", taskId] }
        args += ["--project-path", projectPath, "--agent-id", agentId]
        return ["mcpServers": [serverName: ["command": command, "args": args]]]
    }
}
