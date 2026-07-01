// SPDX-License-Identifier: MIT
import Foundation

/// App-level kill-switch for the MCP capability layer. This is a rollout guard,
/// not a user feature toggle. Default-ON as of Phase 4 (proven across phases);
/// set `atelier.mcpCapabilityEnabled` = false in UserDefaults to disable. When
/// off, no worker gets `--mcp-config` and the pure file+git contract is unchanged.
enum MCPCapability {
    static let defaultsKey = "atelier.mcpCapabilityEnabled"

    /// Defaults to `true` (unset → on). Set the `atelier.mcpCapabilityEnabled`
    /// UserDefaults bool to false to hard-disable the whole capability layer.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}
