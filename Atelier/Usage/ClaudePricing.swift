// SPDX-License-Identifier: MIT
import Foundation

/// Approximate USD pricing per 1M tokens for the Claude model family.
///
/// Used by `ClaudeHistoryScanner` to estimate cost when claude's persisted
/// JSONL doesn't include `total_cost_usd` (which is only emitted in the
/// stream-json output, not the on-disk session log).
///
/// These figures track Anthropic's published pricing as of 2026-05; they may
/// drift over time. Adjust here when rates change.
enum ClaudePricing {
    struct Rate {
        let input: Double            // per 1M input tokens
        let output: Double           // per 1M output tokens
        let cacheRead: Double        // per 1M (typically ~10% of input)
        let cacheCreation5m: Double  // per 1M (ephemeral 5m)
        let cacheCreation1h: Double  // per 1M (ephemeral 1h, ~2× creation cost)
    }

    static func rate(forModel raw: String) -> Rate {
        // Map any model id to a family. Pricing per 1M tokens, USD.
        let id = raw.lowercased()
        if id.contains("opus") {
            return Rate(input: 15.0, output: 75.0, cacheRead: 1.50,
                        cacheCreation5m: 18.75, cacheCreation1h: 30.0)
        }
        if id.contains("sonnet") {
            return Rate(input: 3.0, output: 15.0, cacheRead: 0.30,
                        cacheCreation5m: 3.75, cacheCreation1h: 6.0)
        }
        if id.contains("haiku") {
            return Rate(input: 1.0, output: 5.0, cacheRead: 0.10,
                        cacheCreation5m: 1.25, cacheCreation1h: 2.0)
        }
        // Unknown — assume Sonnet-class pricing as a conservative middle.
        return Rate(input: 3.0, output: 15.0, cacheRead: 0.30,
                    cacheCreation5m: 3.75, cacheCreation1h: 6.0)
    }

    /// Estimate cost from a token bag. `cacheCreation5m` and `cacheCreation1h`
    /// can be passed separately; if you only have the aggregate, pass it all
    /// under `cacheCreation5m` for a conservative low-bound.
    static func estimate(model: String,
                         input: Int,
                         output: Int,
                         cacheRead: Int,
                         cacheCreation5m: Int,
                         cacheCreation1h: Int = 0) -> Double {
        let r = rate(forModel: model)
        let scale = 1_000_000.0
        return Double(input)            * r.input            / scale
             + Double(output)           * r.output           / scale
             + Double(cacheRead)        * r.cacheRead        / scale
             + Double(cacheCreation5m)  * r.cacheCreation5m  / scale
             + Double(cacheCreation1h)  * r.cacheCreation1h  / scale
    }
}
