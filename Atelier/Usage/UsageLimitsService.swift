// SPDX-License-Identifier: MIT
import Foundation
import Security
import os

/// Best-effort fetch of the user's Claude **subscription** usage limits — the same
/// 5-hour + weekly utilization and reset times that Claude Code's `/usage` panel
/// shows.
///
/// This is UNOFFICIAL and inherently fragile: it reuses the OAuth token `claude`
/// stores in the login Keychain (`Claude Code-credentials`) and calls the
/// undocumented `https://api.anthropic.com/api/oauth/usage` endpoint with the same
/// `anthropic-beta: oauth-2025-04-20` header the CLI uses. Any Claude Code update
/// can move the token, the endpoint, or the schema — so every failure path
/// degrades to a thrown error the UI renders as "unavailable", never a crash.
///
/// We never refresh the token (that would mean touching claude's own credentials).
/// When it has expired, the user just needs to run any `claude` command — the CLI
/// refreshes it in place — then reload here.
enum UsageLimitsService {
    private static let logger = Logger(subsystem: "app.atelier", category: "usage-limits")
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    /// One rolling window (utilization is a 0–100 percentage).
    struct Window: Sendable, Hashable {
        let utilization: Double
        let resetsAt: Date?
    }

    struct Limits: Sendable, Hashable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let subscriptionType: String?
        let fetchedAt: Date
    }

    enum LimitsError: Swift.Error, LocalizedError {
        case noCredential
        case expired
        case http(Int)
        case decode

        var errorDescription: String? {
            switch self {
            case .noCredential: return "No Claude subscription credential found in the Keychain."
            case .expired: return "Claude Code's stored login is stale (it refreshes on its own schedule). Reload in a moment, or run any `claude` command to refresh it now."
            case .http(let code): return "Usage endpoint returned HTTP \(code)."
            case .decode: return "Could not decode the usage response."
            }
        }
    }

    static func fetch() async throws -> Limits {
        guard let cred = readCredential() else { throw LimitsError.noCredential }

        // No client-side expiry pre-check: the stored `expiresAt` is unreliable
        // (Claude Code often refreshes in memory and writes back late). We just
        // make the call and treat a 401 as "stale token" — reactive, not proactive.
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LimitsError.http(-1) }
        guard http.statusCode == 200 else {
            logger.warning("usage endpoint HTTP \(http.statusCode, privacy: .public)")
            throw http.statusCode == 401 ? LimitsError.expired : LimitsError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LimitsError.decode
        }
        return Limits(
            fiveHour: window(obj["five_hour"]),
            sevenDay: window(obj["seven_day"]),
            sevenDayOpus: window(obj["seven_day_opus"]),
            sevenDaySonnet: window(obj["seven_day_sonnet"]),
            subscriptionType: cred.subscriptionType,
            fetchedAt: Date()
        )
    }

    private static func window(_ raw: Any?) -> Window? {
        guard let d = raw as? [String: Any],
              let util = d["utilization"] as? Double else { return nil }
        let reset = (d["resets_at"] as? String).flatMap(parseISO)
        return Window(utilization: util, resetsAt: reset)
    }

    // MARK: - Credential (read-only)

    private struct Credential {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
    }

    /// Reads claude's OAuth blob from the login Keychain. The first read from
    /// Atelier triggers the standard one-time "allow access" prompt; after the
    /// user clicks "Always Allow" it's silent. Returns nil on any failure.
    private static func readCredential() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            if status != errSecSuccess && status != errSecItemNotFound {
                logger.warning("keychain read failed: \(status, privacy: .public)")
            }
            return nil
        }
        // expiresAt is epoch milliseconds.
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credential(accessToken: token,
                          expiresAt: expiresAt,
                          subscriptionType: oauth["subscriptionType"] as? String)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
