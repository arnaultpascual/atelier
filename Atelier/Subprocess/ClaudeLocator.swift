// SPDX-License-Identifier: MIT
import Foundation

/// Locates the `claude` executable on the host.
///
/// Apps launched from Finder don't inherit the user's shell `$PATH`, so we can't rely
/// on `Subprocess.run(.name("claude"))`. We probe well-known install locations and fall
/// back to spawning `/bin/zsh -lc 'command -v claude'` for users who have it elsewhere.
enum ClaudeLocator {
    static let candidatePaths: [String] = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude",
        "/usr/bin/claude"
    ]

    /// UserDefaults key holding a user-picked `claude` path, set from the Setup
    /// Assistant when claude lives somewhere off the standard list.
    static let overrideKey = "atelier.claudePathOverride"

    /// Persists (or clears, when nil/empty) a manual override for the `claude` path.
    static func setOverridePath(_ path: String?) {
        if let path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: overrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        }
    }

    /// Returns the absolute path of `claude` or `nil` if not found. A user-picked
    /// override (Setup Assistant) wins, then the well-known locations, then a login
    /// shell probe.
    static func locate() -> String? {
        let fm = FileManager.default
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty, fm.isExecutableFile(atPath: override) {
            return override
        }
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return locateViaLoginShell()
    }

    private static func locateViaLoginShell() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v claude"]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }
}
