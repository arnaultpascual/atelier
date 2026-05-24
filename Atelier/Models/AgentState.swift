// SPDX-License-Identifier: MIT
import Foundation
import Observation

@MainActor
@Observable
final class AgentState {
    enum Status: Sendable, Equatable {
        case idle
        case starting
        case running
        case awaitingApproval
        case completed
        case failed(reason: String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .starting: return "Starting"
            case .running: return "Running"
            case .awaitingApproval: return "Awaiting approval"
            case .completed: return "Completed"
            case .failed: return "Failed"
            }
        }
    }

    struct ApprovalRecord: Identifiable, Sendable {
        let id: UUID = UUID()
        let toolUseId: String
        let toolName: String
        let inputJSON: String
        let receivedAt: Date = Date()
        let resolution: String
    }

    var status: Status = .idle
    var events: [StreamEvent] = []
    var totalCostUsd: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
    var sessionId: String?
    var resolvedModel: String?
    var approvalHistory: [ApprovalRecord] = []
    var lastErrorMessage: String?
    var stderrLines: [String] = []

    func reset() {
        status = .starting
        events = []
        totalCostUsd = 0
        inputTokens = 0
        outputTokens = 0
        cacheCreationTokens = 0
        cacheReadTokens = 0
        sessionId = nil
        resolvedModel = nil
        approvalHistory = []
        lastErrorMessage = nil
        stderrLines = []
    }

    func appendStderr(_ line: String) {
        stderrLines.append(line)
        if stderrLines.count > 200 {
            stderrLines.removeFirst(stderrLines.count - 200)
        }
    }

    func ingest(_ event: StreamEvent) {
        events.append(event)
        switch event.kind {
        case .system(_, let sessionId, let model):
            self.sessionId = sessionId
            self.resolvedModel = model
            if status == .starting { status = .running }
        case .assistant:
            if status == .starting { status = .running }
        case .result(_, let cost, let usage, let isError):
            // result events emit the cost of *this* worker invocation. Accumulate
            // so iterate (--resume) turns add to the prior session's running
            // total instead of overwriting it.
            if let c = cost { totalCostUsd += c }
            if let u = usage {
                inputTokens += u.inputTokens
                outputTokens += u.outputTokens
                cacheCreationTokens += u.cacheCreationTokens
                cacheReadTokens += u.cacheReadTokens
            }
            status = isError ? .failed(reason: "Worker reported is_error=true") : .completed
        case .malformed(let reason):
            lastErrorMessage = "Malformed event: \(reason)"
        default:
            break
        }
    }

    func recordApproval(toolUseId: String, toolName: String, inputJSON: String, resolution: String) {
        approvalHistory.append(.init(
            toolUseId: toolUseId,
            toolName: toolName,
            inputJSON: inputJSON,
            resolution: resolution
        ))
    }

    func markFailed(_ reason: String) {
        status = .failed(reason: reason)
        lastErrorMessage = reason
    }

    /// True when this worker stopped because of an Anthropic usage/rate limit rather than a real
    /// failure. A structured `rate_limit_event` is definitive; otherwise scan the last error and
    /// recent stderr for the usual signatures. Used to offer a Resume/Relaunch instead of treating
    /// the stop as a permanent failure (autopilot pauses; a normal swarm shows a relaunch button).
    var looksUsageLimited: Bool {
        for event in events {
            if case .rateLimit = event.kind { return true }
        }
        let haystack = ([lastErrorMessage].compactMap { $0 } + stderrLines.suffix(25))
            .joined(separator: "\n")
            .lowercased()
        guard !haystack.isEmpty else { return false }
        let needles = ["usage limit", "rate limit", "rate_limit", "resets at", "limit reached",
                       "too many requests", "overloaded", "quota", " 429", "429 "]
        return needles.contains { haystack.contains($0) }
    }
}
