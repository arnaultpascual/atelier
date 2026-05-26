// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Settings scene shown via ⌘, on macOS.
///
/// Tabs: Authentication (API key / OAuth), Alerts (daily budget), Skills
/// (the bundled SKILL.md catalog), and Diagnostics (environment checks).
struct SettingsView: View {
    var body: some View {
        TabView {
            APIKeyTab()
                .tabItem {
                    Label("Authentication", systemImage: "key")
                }
                .padding(24)
            AlertsTab()
                .tabItem {
                    Label("Alerts", systemImage: "bell.badge")
                }
                .padding(24)
            SkillsTab()
                .tabItem {
                    Label("Skills", systemImage: "sparkles")
                }
                .padding(24)
            DiagnosticsTab()
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 440)
    }
}

// MARK: - Alerts tab

private struct AlertsTab: View {
    @AppStorage("usage.dailyBudgetUsd") private var dailyBudgetUsd: Double = 0
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Daily budget",
                          subtitle: "Atelier flags the Usage dashboard when today's spend goes over this threshold. Includes both Atelier-spawned runs and the rest of your claude usage (estimated from token counts).")

            VStack(alignment: .leading, spacing: 8) {
                Text("DAILY BUDGET (USD)")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                HStack(spacing: 8) {
                    TextField("e.g. 5.00 — leave empty for none",
                              text: $draft,
                              onCommit: save)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil && !draft.isEmpty)
                    if dailyBudgetUsd > 0 {
                        Button(role: .destructive) {
                            dailyBudgetUsd = 0
                            draft = ""
                        } label: {
                            Text("Clear")
                        }
                    }
                }
                if dailyBudgetUsd > 0 {
                    Text(String(format: "Active: alert above $%.2f / day.", dailyBudgetUsd))
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.success)
                } else {
                    Text("No daily budget set.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What counts towards today")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text("Any claude session whose first event lands on the local day. Cost is exact for Atelier-spawned runs, estimated from token counts × published rates for everything else recorded under ~/.claude/projects/.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            draft = dailyBudgetUsd > 0 ? String(format: "%.2f", dailyBudgetUsd) : ""
        }
    }

    private var parsed: Double? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        // Accept both "." and "," as decimal separators.
        let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalised), v >= 0 else { return nil }
        return v
    }

    private func save() {
        guard let v = parsed else { return }
        dailyBudgetUsd = v
        if v == 0 { draft = "" }
    }
}

// MARK: - API key tab

private struct APIKeyTab: View {
    @State private var draftKey: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var resolvedSource: APIKeyResolver.Source = .subscription
    @State private var saveError: String?
    @State private var saveOk: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Anthropic API key",
                          subtitle: "Stored in the macOS Keychain (service \"app.atelier\").")

            currentSource

            VStack(alignment: .leading, spacing: 8) {
                Text("KEY")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                SecureField(hasStoredKey ? "•••••• (currently stored)" : "sk-ant-…", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if let saveError {
                    Text(saveError)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.error)
                }
                if saveOk {
                    Text("Saved.")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.success)
                }
            }

            HStack(spacing: 8) {
                if hasStoredKey {
                    Button(role: .destructive, action: clear) {
                        Text("Clear stored key")
                    }
                }
                Spacer()
                Button(action: save) {
                    Text("Save")
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Order of precedence at spawn time")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                Text("1. Keychain (this tab)\n2. ANTHROPIC_API_KEY env var inherited from the launching shell\n3. Subscription credentials via `claude auth` (Pro/Max/Enterprise)")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .onAppear(perform: reload)
    }

    private var currentSource: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text("Active source:")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Text(sourceLabel)
                .font(AtelierFont.caption.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var sourceLabel: String {
        switch resolvedSource {
        case .keychain: return "Keychain (this app)"
        case .environment: return "Environment — ANTHROPIC_API_KEY"
        case .subscription: return "Subscription (claude auth)"
        }
    }

    private var badgeColor: Color {
        switch resolvedSource {
        case .keychain: return Palette.success
        case .environment: return Palette.warning
        case .subscription: return Color.atelierInkSecondary
        }
    }

    private func reload() {
        hasStoredKey = KeychainStore.loadAPIKey() != nil
        resolvedSource = APIKeyResolver.describeSource()
        draftKey = ""
        saveError = nil
        saveOk = false
    }

    private func save() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.saveAPIKey(key)
            saveError = nil
            saveOk = true
            reload()
        } catch {
            saveError = error.localizedDescription
            saveOk = false
        }
    }

    private func clear() {
        do {
            try KeychainStore.deleteAPIKey()
            reload()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Diagnostics tab

private struct DiagnosticsTab: View {
    @State private var helperPath: String?
    @State private var claudePath: String?
    @State private var gitPath: String?
    @State private var authSource: APIKeyResolver.Source = .subscription
    @State private var pendingSockets: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Bundled binaries",
                          subtitle: "Resolved at app launch.")
            diagRow("claude CLI", value: claudePath ?? "(not found in PATH)",
                    ok: claudePath != nil)
            diagRow("git", value: gitPath ?? "(not found)",
                    ok: gitPath != nil)
            diagRow("AtelierApprovalHelper", value: helperPath ?? "(missing from bundle)",
                    ok: helperPath != nil)
            diagRow("Authentication", value: authLabel, ok: true)

            sectionHeader("Stale approval sockets", subtitle: "Under /tmp/at-ap-*.sock — should be empty when no workers are running.")
            if pendingSockets.isEmpty {
                Text("None.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            } else {
                ForEach(pendingSockets, id: \.self) { p in
                    Text(p)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.atelierInkSecondary)
                        .textSelection(.enabled)
                }
                Button("Clean up") { cleanupSockets() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func diagRow(_ label: String, value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Palette.success : Palette.error)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(AtelierFont.callout.weight(.medium))
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var authLabel: String {
        switch authSource {
        case .keychain: return "API key (Keychain)"
        case .environment: return "ANTHROPIC_API_KEY (environment)"
        case .subscription: return "Subscription (claude auth)"
        }
    }

    private func reload() {
        helperPath = MCPConfig.helperPath()
        claudePath = ClaudeLocator.locate()
        gitPath = GitService.locate()
        authSource = APIKeyResolver.describeSource()
        pendingSockets = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp"))?
            .filter { $0.hasPrefix("at-ap-") && $0.hasSuffix(".sock") }
            .map { "/tmp/\($0)" } ?? []
    }

    private func cleanupSockets() {
        for p in pendingSockets {
            try? FileManager.default.removeItem(atPath: p)
        }
        reload()
    }
}

// MARK: - Shared

@ViewBuilder
private func sectionHeader(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(.system(.title3, design: .serif).weight(.semibold))
            .foregroundStyle(Color.atelierInk)
        Text(subtitle)
            .font(AtelierFont.caption)
            .foregroundStyle(Color.atelierInkSecondary)
    }
}
