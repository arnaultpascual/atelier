// SPDX-License-Identifier: MIT
import Foundation

/// App-level kill-switch for the MCP capability layer. This is a rollout guard,
/// not a user feature toggle: OFF through Phases 1–3, flipped ON in Phase 4 once
/// proven. When OFF, no worker gets `--mcp-config` and the pure file+git contract
/// is unchanged.
enum MCPCapability {
    static let defaultsKey = "atelier.mcpCapabilityEnabled"

    /// Defaults to `false` (unset → off). Set the `atelier.mcpCapabilityEnabled`
    /// UserDefaults bool to true to enable during development/testing.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }
}
