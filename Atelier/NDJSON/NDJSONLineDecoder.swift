// SPDX-License-Identifier: MIT
import Foundation

/// Decodes a single NDJSON line into a `StreamEvent`.
///
/// `swift-subprocess`'s `.lines()` API already splits on newlines for us, so we don't
/// need an actor-buffered parser in Phase 0 — just a stateless mapping from line to event.
/// Empty / whitespace-only lines are dropped.
public struct NDJSONLineDecoder: Sendable {
    public init() {}

    public func decode(_ line: String) -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return StreamEvent(rawLine: trimmed)
    }
}
