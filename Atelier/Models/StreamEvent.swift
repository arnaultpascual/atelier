// SPDX-License-Identifier: MIT
import Foundation

/// One line from `claude -p --output-format stream-json`, decoded permissively.
///
/// The raw line is preserved verbatim for display and debugging; the `kind` field
/// extracts the most-useful fields by best effort. Unknown shapes degrade to `.unknown`
/// rather than throwing — Phase 0 must tolerate Claude Code version drift.
public struct StreamEvent: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let rawLine: String
    public let prettyJSON: String
    public let kind: Kind

    public enum Kind: Sendable, Hashable {
        case system(subtype: String?, sessionId: String?, model: String?)
        case assistant(text: String?, hasThinking: Bool, toolUses: [ToolUse])
        case user(toolResults: [ToolResult])
        case result(subtype: String?, totalCostUsd: Double?, usage: Usage?, isError: Bool)
        case streamEvent(eventType: String?)
        case rateLimit(message: String?)
        case malformed(reason: String)
        case unknown(typeName: String?)

        public var displayLabel: String {
            switch self {
            case .system: return "system"
            case .assistant: return "assistant"
            case .user: return "user"
            case .result: return "result"
            case .streamEvent: return "stream_event"
            case .rateLimit: return "rate_limit_event"
            case .malformed: return "malformed"
            case .unknown(let t): return t ?? "unknown"
            }
        }
    }

    public struct ToolUse: Sendable, Hashable {
        public let id: String
        public let name: String
        public let inputJSON: String

        /// Tool-specific one-line summary suitable for kanban cards / event timeline.
        /// Falls back to the raw JSON when the tool is unknown.
        public var oneLineSummary: String {
            guard let data = inputJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return inputJSON
            }
            switch name {
            case "Bash":
                return (obj["command"] as? String) ?? inputJSON
            case "Read", "Write", "Edit", "NotebookEdit":
                return (obj["file_path"] as? String) ?? inputJSON
            case "Glob", "Grep":
                let pattern = obj["pattern"] as? String ?? ""
                let path = obj["path"] as? String ?? ""
                return path.isEmpty ? pattern : "\(pattern) in \(path)"
            case "ToolSearch":
                return (obj["query"] as? String) ?? inputJSON
            case "WebFetch":
                return (obj["url"] as? String) ?? inputJSON
            case "WebSearch":
                return (obj["query"] as? String) ?? inputJSON
            case "TodoWrite":
                if let todos = obj["todos"] as? [[String: Any]] {
                    return "\(todos.count) todo\(todos.count == 1 ? "" : "s")"
                }
                return inputJSON
            case "Agent":
                return (obj["description"] as? String)
                    ?? (obj["prompt"] as? String).map { String($0.prefix(80)) }
                    ?? inputJSON
            default:
                return inputJSON
            }
        }
    }

    public struct ToolResult: Sendable, Hashable {
        public let toolUseId: String
        public let isError: Bool
        public let textSummary: String
    }

    public struct Usage: Sendable, Hashable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheCreationTokens: Int
        public let cacheReadTokens: Int
    }

    public init(rawLine: String) {
        self.id = UUID()
        self.rawLine = rawLine
        let (pretty, timestamp, kind) = Self.parse(rawLine)
        self.timestamp = timestamp
        self.prettyJSON = pretty
        self.kind = kind
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

    private static func parse(_ line: String) -> (String, Date, Kind) {
        let now = Date()
        guard let data = line.data(using: .utf8) else {
            return (line, now, .malformed(reason: "non-utf8 line"))
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return (line, now, .malformed(reason: "invalid JSON: \(error.localizedDescription)"))
        }
        let pretty: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) else { return line }
            return String(data: data, encoding: .utf8) ?? line
        }()
        guard let dict = obj as? [String: Any] else {
            return (pretty, now, .unknown(typeName: nil))
        }
        let timestamp: Date = {
            if let ts = dict["timestamp"] as? String {
                if let d = isoFormatterFractional.date(from: ts) { return d }
                if let d = isoFormatter.date(from: ts) { return d }
            }
            return now
        }()
        let type = dict["type"] as? String
        switch type {
        case "system":
            return (pretty, timestamp, .system(
                subtype: dict["subtype"] as? String,
                sessionId: dict["session_id"] as? String ?? dict["sessionId"] as? String,
                model: dict["model"] as? String
            ))
        case "assistant":
            return (pretty, timestamp, parseAssistant(dict))
        case "user":
            return (pretty, timestamp, parseUser(dict))
        case "result":
            return (pretty, timestamp, parseResult(dict))
        case "stream_event":
            let eventType = (dict["event"] as? [String: Any])?["type"] as? String
            return (pretty, timestamp, .streamEvent(eventType: eventType))
        case "rate_limit_event":
            let message = (dict["message"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["reason"] as? String)
            return (pretty, timestamp, .rateLimit(message: message))
        default:
            return (pretty, timestamp, .unknown(typeName: type))
        }
    }

    private static func parseAssistant(_ dict: [String: Any]) -> Kind {
        let message = dict["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []
        var combinedText = ""
        var hasThinking = false
        var toolUses: [ToolUse] = []
        for block in content {
            let blockType = block["type"] as? String
            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    if !combinedText.isEmpty { combinedText += "\n" }
                    combinedText += text
                }
            case "thinking":
                hasThinking = true
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? "unknown"
                let input = block["input"] as? [String: Any] ?? [:]
                let inputJSON: String = {
                    guard let data = try? JSONSerialization.data(
                        withJSONObject: input,
                        options: [.sortedKeys, .withoutEscapingSlashes]
                    ) else { return "{}" }
                    return String(data: data, encoding: .utf8) ?? "{}"
                }()
                toolUses.append(ToolUse(id: id, name: name, inputJSON: inputJSON))
            default:
                break
            }
        }
        return .assistant(
            text: combinedText.isEmpty ? nil : combinedText,
            hasThinking: hasThinking,
            toolUses: toolUses
        )
    }

    private static func parseUser(_ dict: [String: Any]) -> Kind {
        let message = dict["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []
        var results: [ToolResult] = []
        for block in content {
            guard (block["type"] as? String) == "tool_result" else { continue }
            let toolUseId = block["tool_use_id"] as? String ?? ""
            let isError = block["is_error"] as? Bool ?? false
            var summary = ""
            if let str = block["content"] as? String {
                summary = str
            } else if let arr = block["content"] as? [[String: Any]] {
                for chunk in arr {
                    if let t = chunk["text"] as? String {
                        if !summary.isEmpty { summary += "\n" }
                        summary += t
                    }
                }
            }
            results.append(ToolResult(toolUseId: toolUseId, isError: isError, textSummary: summary))
        }
        return .user(toolResults: results)
    }

    private static func parseResult(_ dict: [String: Any]) -> Kind {
        let subtype = dict["subtype"] as? String
        let cost = dict["total_cost_usd"] as? Double
        let isError: Bool = {
            if let b = dict["is_error"] as? Bool { return b }
            return subtype?.hasPrefix("error") ?? false
        }()
        let usage: Usage? = {
            guard let u = dict["usage"] as? [String: Any] else { return nil }
            return Usage(
                inputTokens: u["input_tokens"] as? Int ?? 0,
                outputTokens: u["output_tokens"] as? Int ?? 0,
                cacheCreationTokens: u["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0
            )
        }()
        return .result(subtype: subtype, totalCostUsd: cost, usage: usage, isError: isError)
    }
}
