// SPDX-License-Identifier: MIT
import Foundation

/// Unified usage row consumed by the Usage dashboard.
///
/// Two sources merge into this type:
///   - **Atelier** — every `Agent` row Atelier has spawned itself.
///   - **History** — scanned from claude's persisted JSONL at
///     `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`. Surfaces
///     pre-Atelier claude usage so the dashboard shows the user's full
///     spend, not just what Atelier orchestrated.
///
/// Deduped by `sessionId`: when both sources have the same session, the
/// Atelier record wins (richer context — project name, task id).
struct UsageRecord: Identifiable, Hashable {
    let id: String
    let sessionId: String?
    let model: String
    let costUsd: Double
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let startedAt: Date
    let source: Source
    /// Stable grouping key — projectId for Atelier rows, encoded dir name for
    /// History rows. Use this to bucket by project.
    let projectKey: String
    /// Human-readable label for the project (e.g. "MyApp" or the last
    /// path segment of `~/.claude/projects/-Users-…-atelier`).
    let projectDisplay: String

    enum Source: String, Hashable {
        case atelier   // spawned and tracked by Atelier
        case history   // discovered by scanning ~/.claude/projects/
    }
}
