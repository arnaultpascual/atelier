// SPDX-License-Identifier: MIT
import Foundation
import os

/// The per-spawn scaffolding shared by every worker `TaskSpawner` launches:
///   - the approval Unix-socket listener + its `--settings` PreToolUse hook config
///     (the approval path — always present), and
///   - the OPTIONAL feature-scoped MCP capability bridge + its `--mcp-config`.
///
/// Owning this in one place keeps the guardrail-sensitive lifecycle — socket
/// start/stop, temp-config cleanup, and the `setMCPCapability(true/false)` pairing —
/// SINGLE-SOURCED, so it can't drift across the build / iterate / managed spawn
/// paths (previously the same ~40 lines were copy-pasted three times).
///
/// Symmetry contract: every `begin` that returns is matched by exactly one
/// `tearDown`. `begin` throws only if the approval socket or its settings config
/// can't be created (that path is mandatory); an MCP-bridge failure is non-fatal —
/// it logs and the session simply carries no MCP (the file+git contract still holds).
@MainActor
struct WorkerSpawnSession {
    private static let logger = Logger(subsystem: "app.atelier", category: "spawn-session")

    let agentId: UUID
    /// Path for `claude --settings` (approval hook). Always present.
    let settingsPath: String
    /// Path for `claude --mcp-config` when the MCP layer is attached, else nil.
    let mcpConfigPath: String?
    /// The feature the MCP layer is scoped to (for prompt augmentation), else nil
    /// (nil when the kill-switch is off, the spawn isn't feature-scoped, or MCP
    /// setup failed and we fell back to the pure file+git contract).
    let mcpFeatureId: String?

    private let approvalListener: ApprovalSocketListener
    private let mcpBridge: AtelierBridgeListener?
    private let settingsURL: URL
    private let mcpConfigURL: URL?
    private let approvalQueue: ApprovalQueue

    /// Starts the approval socket + settings config, loads permission rules, and
    /// (when `mcpFeatureId != nil` and the kill-switch is on) attaches the MCP
    /// capability bridge + config. Throws on approval-socket / settings-config
    /// failure (the listener is stopped before throwing on the latter).
    static func begin(agentId: UUID,
                      approvalTaskId: String,
                      project: Project,
                      rulesWorktreePath: String,
                      server: ApprovalServer,
                      approvalQueue: ApprovalQueue,
                      autopilot: Bool,
                      mcpFeatureId: String?,
                      mcpTaskId: String?,
                      store: AppStore,
                      extraDenyRules: [PermissionRule] = []) async throws -> WorkerSpawnSession {
        let listener = ApprovalSocketListener(agentId: agentId.uuidString,
                                              taskId: approvalTaskId,
                                              projectName: project.name,
                                              queue: approvalQueue)
        let socketPath = try await listener.start()
        approvalQueue.loadRules(forAgent: agentId.uuidString, project: project, worktreePath: rulesWorktreePath)
        // Hard fences (deny) that must win even under autopilot auto-accept.
        approvalQueue.prependRunRules(forAgent: agentId.uuidString, extraDenyRules)
        if autopilot { approvalQueue.setAutopilot(true, forAgent: agentId.uuidString) }

        let settingsURL: URL
        do {
            settingsURL = try MCPConfig.writeTemporaryConfig(serverName: server.serverName,
                                                             agentId: agentId, socketPath: socketPath)
        } catch {
            await listener.stop(reason: "config write failed")
            throw error
        }

        // Optional MCP capability layer — additive; any failure → continue without it.
        var bridge: AtelierBridgeListener? = nil
        var mcpURL: URL? = nil
        var attachedFeatureId: String? = nil
        if MCPCapability.isEnabled, let fid = mcpFeatureId {
            let b = AtelierBridgeListener(agentId: agentId.uuidString, featureId: fid,
                                          projectPath: project.path, store: store)
            do {
                let mcpSocket = try await b.start()
                mcpURL = try MCPServerConfig.writeTemporaryConfig(agentId: agentId, socketPath: mcpSocket,
                                                                  featureId: fid, taskId: mcpTaskId,
                                                                  projectPath: project.path)
                bridge = b
                approvalQueue.setMCPCapability(true, forAgent: agentId.uuidString)
                attachedFeatureId = fid
            } catch {
                logger.warning("mcp capability setup failed, continuing without: \(error.localizedDescription, privacy: .public)")
                await b.stop(reason: "mcp setup failed")
                bridge = nil; mcpURL = nil
            }
        }

        return WorkerSpawnSession(agentId: agentId,
                                  settingsPath: settingsURL.path,
                                  mcpConfigPath: mcpURL?.path,
                                  mcpFeatureId: attachedFeatureId,
                                  approvalListener: listener,
                                  mcpBridge: bridge,
                                  settingsURL: settingsURL,
                                  mcpConfigURL: mcpURL,
                                  approvalQueue: approvalQueue)
    }

    /// Cleans the settings config, stops the approval socket, and — when MCP was
    /// attached — cleans the MCP config, stops the bridge, and clears the agent's
    /// MCP-capability flag. Symmetric with `begin`; safe to call exactly once.
    func tearDown(reason: String) async {
        MCPConfig.cleanup(settingsURL)
        await approvalListener.stop(reason: reason)
        if let mcpConfigURL { MCPServerConfig.cleanup(mcpConfigURL) }
        if let mcpBridge {
            await mcpBridge.stop(reason: reason)
            approvalQueue.setMCPCapability(false, forAgent: agentId.uuidString)
        }
    }
}
