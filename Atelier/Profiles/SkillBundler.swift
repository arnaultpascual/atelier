// SPDX-License-Identifier: MIT
import Foundation
import os

/// Copies bundled SKILL.md files into a worktree at spawn time.
///
/// Layout in the .app bundle (under `Contents/Resources/Skills/`):
///
///   universal/<skill>/SKILL.md       — loaded for every spawn
///   profiles/<profile-id>/<skill>/SKILL.md   — loaded when the project's profile matches
///
/// Target in the worktree:
///
///   <worktree>/.claude/skills/<skill>/SKILL.md
///
/// Claude auto-discovers `.claude/skills/<name>/SKILL.md` when the worker
/// starts in that directory, so no extra wiring is needed in the prompt or
/// settings. Cleanup happens with the worktree itself.
enum SkillBundler {
    private static let logger = Logger(subsystem: "app.atelier", category: "skills")

    /// Installs universal + profile-matched skills into the worktree. Idempotent —
    /// overwrites existing skills of the same name (so an Atelier upgrade ships
    /// new versions to ongoing worktrees).
    @discardableResult
    static func installSkills(worktreePath: String, profileId: String?) -> InstallReport {
        let dest = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
        var report = InstallReport()

        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            logger.error("could not create skills dir: \(error.localizedDescription, privacy: .public)")
            report.errors.append("mkdir .claude/skills: \(error.localizedDescription)")
            return report
        }

        copyTree(named: "universal", into: dest, report: &report)
        let matchedProfileId = profileId ?? ProjectProfile.generic.id
        copyTree(named: "profiles/\(matchedProfileId)", into: dest, report: &report)

        logger.info("installed \(report.installedNames.count) skills at \(dest.path, privacy: .public): \(report.installedNames.joined(separator: ", "), privacy: .public)")
        return report
    }

    private static func copyTree(named relativePath: String, into dest: URL, report: inout InstallReport) {
        guard let source = bundledSkillsRoot()?.appendingPathComponent(relativePath) else {
            report.errors.append("Skills/ missing from bundle Resources")
            return
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            // Profile-specific skills may not exist for every profile — that's OK.
            return
        }
        let skillDirs = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for skillURL in skillDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: skillURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillName = skillURL.lastPathComponent
            let target = dest.appendingPathComponent(skillName)
            // Overwrite by removing first so we don't merge stale files.
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: skillURL, to: target)
                report.installedNames.append(skillName)
            } catch {
                report.errors.append("\(skillName): \(error.localizedDescription)")
            }
        }
    }

    private static func bundledSkillsRoot() -> URL? {
        if let url = Bundle.main.url(forResource: "Skills", withExtension: nil) {
            return url
        }
        // Fallback for development builds where the folder reference may resolve
        // under Contents/Resources directly.
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("Skills")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    struct InstallReport: Sendable {
        var installedNames: [String] = []
        var errors: [String] = []
    }
}
