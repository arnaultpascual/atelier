// SPDX-License-Identifier: MIT
import Foundation

/// Detects whether a project already has coverage tooling wired for its mode, and
/// exposes the self-contained instructions to wire it if not.
///
/// Detection is pure (a bounded filesystem scan for config markers); WIRING is
/// only ever applied on explicit user opt-in, by spawning a setup worker with
/// `setupInstructions` (see the feature-flow prerequisites step). We never mutate
/// the user's build files silently. Backed by `ProjectProfile.CoverageSetup`.
enum CoverageEnablement {
    enum Status: Equatable, Sendable {
        case notSupported          // no known coverage story for this mode
        case wired                 // coverage tooling detected (or built-in)
        case missing(tool: String) // mode supports coverage but it isn't wired — offer setup
    }

    static func status(profile: ProjectProfile, projectPath: String) -> Status {
        guard let setup = profile.build.coverageSetup else {
            // No setup metadata: a mode with a coverageCommand measures coverage out of the
            // box (built-in); one without simply can't.
            return profile.build.coverageCommand != nil ? .wired : .notSupported
        }
        return isWired(setup, projectPath: projectPath) ? .wired : .missing(tool: setup.toolName)
    }

    static func setupInstructions(profile: ProjectProfile) -> String? {
        profile.build.coverageSetup?.instructions
    }

    /// True if any probe file under `projectPath` contains any marker (case-insensitive).
    /// Prunes build-output / dependency / VCS dirs so generated files can't false-positive.
    static func isWired(_ setup: ProjectProfile.CoverageSetup, projectPath: String) -> Bool {
        let markers = setup.markers.map { $0.lowercased() }
        guard !markers.isEmpty, !setup.probeFiles.isEmpty else { return false }
        let pruned: Set<String> = ["build", "bin", "obj", "node_modules", ".git", ".gradle", ".idea", "DerivedData", ".build"]
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: projectPath),
                                     includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return false }
        var scanned = 0
        for case let url as URL in en {
            if url.pathComponents.contains(where: { pruned.contains($0) }) { en.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard setup.probeFiles.contains(where: { name.hasSuffix($0) }) else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = raw.lowercased()
            if markers.contains(where: { text.contains($0) }) { return true }
            scanned += 1
            if scanned > 500 { break }   // safety bound on huge trees
        }
        return false
    }
}
