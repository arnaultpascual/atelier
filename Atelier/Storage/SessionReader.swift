// SPDX-License-Identifier: MIT
import Foundation
import os

/// Reads claude's persisted session JSONL files at
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. Used by the Review section
/// to recover the worker conversation across Atelier restarts.
///
/// Encoding rule observed empirically (claude 2.1.78): EVERY non-alphanumeric
/// character in the cwd becomes a `-` (no collapsing of runs). It's not just `/`
/// and `.` — spaces count too, which matters because Atelier's chat scratch dirs
/// live under `~/Library/Application Support/Atelier/…`. e.g.
/// `/Users/me/Documents/GitHub/MyApp/.atelier-worktrees/task-001`
/// →   `-Users-me-Documents-GitHub-MyApp--atelier-worktrees-task-001`
/// `/Users/me/Library/Application Support/Atelier/chat-scratch/ABC`
/// →   `-Users-me-Library-Application-Support-Atelier-chat-scratch-ABC`
enum SessionReader {
    private static let logger = Logger(subsystem: "app.atelier", category: "session-reader")

    static var projectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    private static let safeChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func encodedDirectoryName(for cwd: String) -> String {
        String(cwd.map { safeChars.contains($0) ? $0 : "-" })
    }

    static func sessionFileURL(cwd: String, sessionId: String) -> URL {
        projectsRoot
            .appendingPathComponent(encodedDirectoryName(for: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Reads the JSONL at the conventional path, parses each line into a
    /// `StreamEvent` (re-using the same decoder we use for live stream-json).
    /// Skips lines that aren't user / assistant messages (queue-operation, last-prompt, etc.).
    /// Returns `nil` if the file doesn't exist; returns `[]` if it exists but yields no events.
    static func loadEvents(cwd: String, sessionId: String) -> [StreamEvent]? {
        let url = sessionFileURL(cwd: cwd, sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return parseAll(contents: contents)
        } catch {
            logger.warning("Could not read session file \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The id (filename minus `.jsonl`) of the most recently modified session for
    /// `cwd`, or nil if none exists. Lets callers re-read the same session as
    /// either events or chat messages.
    static func latestSessionId(cwd: String) -> String? {
        let dir = projectsRoot.appendingPathComponent(encodedDirectoryName(for: cwd))
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = urls.filter { $0.pathExtension == "jsonl" }.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        return sorted.first?.deletingPathExtension().lastPathComponent
    }

    /// If we lost the sessionId for some reason, fall back to the *latest* JSONL
    /// inside the encoded directory.
    static func loadLatestSession(cwd: String) -> [StreamEvent]? {
        let dir = projectsRoot.appendingPathComponent(encodedDirectoryName(for: cwd))
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = urls.filter { $0.pathExtension == "jsonl" }
        let sorted = candidates.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        guard let latest = sorted.first,
              let contents = try? String(contentsOf: latest, encoding: .utf8) else {
            return nil
        }
        return parseAll(contents: contents)
    }

    // MARK: - Parsing

    private static func parseAll(contents: String) -> [StreamEvent] {
        var events: [StreamEvent] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Skip claude's house-keeping types — they aren't part of the conversation.
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            switch type {
            case "user", "assistant", "system":
                events.append(StreamEvent(rawLine: trimmed))
            case nil, "queue-operation", "last-prompt", "summary", "compact-summary":
                continue
            default:
                // Pass through anything else that StreamEvent already knows about
                // (stream_event, result, rate_limit_event, …).
                events.append(StreamEvent(rawLine: trimmed))
            }
        }
        return events
    }
}
