// SPDX-License-Identifier: MIT
import Foundation

/// Writes the JSON settings file consumed by `claude --settings <path>`.
///
/// As of Phase 1.3c we drove HITL approvals through claude's `PreToolUse`
/// hook system instead of `--permission-prompt-tool`. The hook is loaded
/// synchronously from the settings file, avoiding the async MCP race that
/// broke our earlier attempts.
///
/// Settings shape (additive; merges with the user's `~/.claude/settings.json`):
/// ```json
/// {
///   "hooks": {
///     "PreToolUse": [{
///       "matcher": "*",
///       "hooks": [{
///         "type": "command",
///         "command": "/path/to/AtelierApprovalHelper --agent-id … --socket …",
///         "timeout": 3600
///       }]
///     }]
///   }
/// }
/// ```
enum MCPConfig {
    /// Resolves the helper binary's absolute path. The helper is copied into
    /// `Atelier.app/Contents/MacOS/` by a post-build script.
    static func helperPath() -> String? {
        guard let mainExe = Bundle.main.executableURL else { return nil }
        let helper = mainExe.deletingLastPathComponent()
            .appendingPathComponent("AtelierApprovalHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper.path : nil
    }

    /// Writes the settings JSON and returns its absolute URL. `socketPath` is
    /// the Unix-domain socket Atelier is listening on for approval decisions;
    /// when nil the helper falls back to auto-allow.
    static func writeTemporaryConfig(
        serverName: String = "atelier",
        agentId: UUID,
        socketPath: String? = nil
    ) throws -> URL {
        guard let helper = helperPath() else {
            throw NSError(
                domain: "app.atelier.settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AtelierApprovalHelper binary not found in app bundle. Re-build the project."]
            )
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-settings-\(agentId.uuidString).json")
        var commandParts: [String] = ["\"\(helper)\""]
        commandParts.append("--agent-id")
        commandParts.append(agentId.uuidString)
        if let socketPath {
            commandParts.append("--socket")
            commandParts.append("\"\(socketPath)\"")
        }
        let command = commandParts.joined(separator: " ")

        let payload: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "*",
                        "hooks": [
                            [
                                "type": "command",
                                "command": command,
                                "timeout": 3600
                            ]
                        ]
                    ]
                ]
            ]
        ]
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
}
