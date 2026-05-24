// SPDX-License-Identifier: MIT
import Foundation

/// Snapshot of the host prerequisites Atelier needs in order to actually run agents.
/// Surfaced by the Setup Assistant on first launch and by Settings → Diagnostics.
struct PreflightStatus {
    let claudePath: String?
    let gitPath: String?
    let authSource: APIKeyResolver.Source

    var claudeOK: Bool { claudePath != nil }
    var gitOK: Bool { gitPath != nil }

    /// `claude` + `git` are the hard requirements — without them there's no worktree
    /// and no worker. Auth is "soft": an absent API key just means we defer to a
    /// `claude auth` subscription, which can't be verified without side effects.
    var hardRequirementsMet: Bool { claudeOK && gitOK }
}

enum PreflightService {
    /// Probes the host. Cheap and side-effect-free — it reads only Atelier's own
    /// Keychain item (never claude's, so no access prompt) and does not invoke `git`,
    /// so it's safe to call on launch.
    static func check() -> PreflightStatus {
        PreflightStatus(
            claudePath: ClaudeLocator.locate(),
            gitPath: GitService.locate(),
            authSource: APIKeyResolver.describeSource()
        )
    }
}
