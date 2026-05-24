// SPDX-License-Identifier: MIT
import Foundation
import os

/// Walks `~/.claude/projects/*/*.jsonl` and summarises each session into a
/// single `UsageRecord`. Includes everything claude has done on this machine,
/// not just Atelier-spawned runs.
///
/// Cheap-enough: streaming line-by-line, no model loading. A few thousand
/// sessions take well under a second on a typical Mac. Run from a background
/// task and refresh on user demand.
enum ClaudeHistoryScanner {
    nonisolated(unsafe) private static let logger = Logger(subsystem: "app.atelier", category: "history-scanner")

    static func projectsRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// Returns one `UsageRecord` per session JSONL that has any cost > 0
    /// (we skip empty / aborted sessions). Safe to call off the main actor.
    static func scan() async -> [UsageRecord] {
        await Task.detached(priority: .utility) {
            scanSync()
        }.value
    }

    private static func scanSync() -> [UsageRecord] {
        let root = projectsRoot()
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        // Collect every session file first, then process oldest-first so that
        // a message's cost is attributed to the session that first incurred it.
        var files: [(url: URL, hint: String, mtime: Date)] = []
        for projectDir in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let projectHint = decodeProjectName(projectDir.lastPathComponent)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in entries where file.pathExtension == "jsonl" {
                let mtime = fileModificationDate(file) ?? .distantPast
                files.append((file, projectHint, mtime))
            }
        }
        files.sort { $0.mtime < $1.mtime }

        // Global dedup: claude copies prior messages into new session files on
        // resume/compaction, so the same (message.id, requestId) shows up across
        // multiple files. Counting each once — keyed like `ccusage` — avoids the
        // ~2× inflation. Oldest-first ordering keeps the cost on the original session.
        var seen = Set<String>()
        var out: [UsageRecord] = []
        for f in files {
            out.append(contentsOf: summarize(file: f.url, projectHint: f.hint, seen: &seen))
        }
        return out
    }

    /// Emits ONE `UsageRecord` per `assistant` message, stamped with that message's
    /// own timestamp — not one per session. Bucketing by the message timestamp is
    /// what makes "today", the windows, the heatmap and the streaks correct: a long
    /// or overnight session spreads its cost across the days it actually ran instead
    /// of dumping everything on the day it started.
    private static func summarize(file: URL, projectHint: String, seen: inout Set<String>) -> [UsageRecord] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let sessionId = file.deletingPathExtension().lastPathComponent
        let projectKey = file.deletingLastPathComponent().lastPathComponent
        let fallback = fileModificationDate(file) ?? Date()

        var out: [UsageRecord] = []
        var lastTimestamp: Date?
        var index = 0

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let ts = obj["timestamp"] as? String, let parsed = parseISO(ts) {
                lastTimestamp = parsed
            }
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            // Skip messages already counted in an earlier (older) session file.
            let msgId = (message["id"] as? String) ?? ""
            let reqId = (obj["requestId"] as? String) ?? ""
            let key = msgId + ":" + reqId
            if !msgId.isEmpty || !reqId.isEmpty {
                if !seen.insert(key).inserted { continue }
            }

            let model = (message["model"] as? String) ?? "unknown"
            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            var cacheCreation5m = 0
            var cacheCreation1h = 0
            if let creation = usage["cache_creation"] as? [String: Any] {
                cacheCreation5m = (creation["ephemeral_5m_input_tokens"] as? Int) ?? 0
                cacheCreation1h = (creation["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else {
                cacheCreation5m = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }
            if input == 0 && output == 0 && cacheRead == 0 && cacheCreation5m == 0 && cacheCreation1h == 0 {
                continue
            }

            let cost = ClaudePricing.estimate(
                model: model, input: input, output: output,
                cacheRead: cacheRead, cacheCreation5m: cacheCreation5m, cacheCreation1h: cacheCreation1h
            )
            // Each message carries its own timestamp; fall back to the previous
            // line's timestamp (assistant rows sometimes omit one), then the file.
            let when = lastTimestamp ?? fallback
            index += 1
            out.append(UsageRecord(
                id: key.isEmpty ? "\(sessionId)#\(index)" : key,
                sessionId: sessionId,
                model: model,
                costUsd: cost,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation5m + cacheCreation1h,
                startedAt: when,
                source: .history,
                projectKey: projectKey,
                projectDisplay: projectHint
            ))
        }
        return out
    }

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ s: String) -> Date? {
        if let d = isoFormatterFractional.date(from: s) { return d }
        return isoFormatter.date(from: s)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    /// claude encodes `/` and `.` as `-` when building the dir name. We can't
    /// perfectly recover the original path, but we can prettify the dir name
    /// for display by replacing the leading `--Users-…` pattern.
    private static func decodeProjectName(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else { return encoded }
        // Best effort: strip leading dash, last segment after the final `-`.
        let trimmed = String(encoded.dropFirst())
        if let lastDash = trimmed.lastIndex(of: "-") {
            return String(trimmed[trimmed.index(after: lastDash)...])
        }
        return trimmed
    }
}
