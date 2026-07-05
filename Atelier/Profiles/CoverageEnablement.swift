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
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL
        let rootDepth = root.pathComponents.count
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return false }
        var visited = 0
        for case let url as URL in en {
            // Prune only components BELOW the project root — a project living under a dir
            // literally named build/bin/.build/… must not prune itself away (false 'missing').
            let rel = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if rel.contains(where: { pruned.contains($0) }) { en.skipDescendants(); continue }
            visited += 1
            if visited > 20_000 { break }   // pathological-tree guard; the match below short-circuits
            let name = url.lastPathComponent
            guard setup.probeFiles.contains(where: { name.hasSuffix($0) }) else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = raw.lowercased()
            if markers.contains(where: { text.contains($0) }) { return true }
        }
        return false
    }
}
