// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// App-wide handle to the approval flow.
///
/// Phase 1.3 moved the MCP transport from in-process HTTP (Hummingbird) to a
/// per-spawn stdio subprocess (`AtelierApprovalHelper`). This type no longer
/// hosts the protocol stack; it just exposes the names used in the claude
/// `--permission-prompt-tool` flag and a readiness flag based on whether the
/// helper binary is present in the app bundle.
@MainActor
@Observable
final class ApprovalServer {
    nonisolated private static let logger = Logger(subsystem: "app.atelier", category: "mcp")

    let serverName = "atelier"
    let toolName = "approval_prompt"

    /// Set at startup by `startIfNeeded()` — true when the helper binary is
    /// resolved inside the .app bundle. UI gates the Spawn button on this.
    private(set) var helperReady: Bool = false
    private(set) var helperPath: String?

    func startIfNeeded() async throws {
        guard !helperReady else { return }
        if let path = MCPConfig.helperPath() {
            helperPath = path
            helperReady = true
            Self.logger.info("approval helper resolved at \(path, privacy: .public)")
        } else {
            Self.logger.error("approval helper missing from app bundle")
        }
    }

    func shutdown() {
        // No-op — the stdio helper is a per-spawn subprocess managed by claude.
    }
}
