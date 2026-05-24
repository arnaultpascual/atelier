// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// First-launch setup assistant. Verifies the host prerequisites Atelier needs to run
/// agents — the `claude` CLI, `git`, and authentication — and offers guided remediation.
/// Presented on first launch and whenever the hard prerequisites are missing; reopenable
/// from the app menu (Setup Assistant…).
struct OnboardingView: View {
    @AppStorage("atelier.onboarding.completed") private var completed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var status = PreflightService.check()

    private let installDocsURL = URL(string: "https://docs.claude.com/en/docs/claude-code")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.atelierDivider)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    claudeRow
                    gitRow
                    authRow
                }
                .padding(22)
            }
            Divider().background(Color.atelierDivider)
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 540, idealHeight: 640)
        .background(Color.atelierBackground)
        .foregroundStyle(Color.atelierInk)
        .tint(Color.atelierAccent)
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Atelier")
                .font(.system(.title, design: .serif).weight(.semibold))
            Text("A quick check that everything Atelier needs is in place. Atelier drives the `claude` CLI on your real repositories, so these prerequisites live on your machine — not inside the app.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { status = PreflightService.check() } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            if !status.hardRequirementsMet {
                Text("You can continue, but spawning needs claude + git.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.warning)
            }
            Spacer()
            Button {
                completed = true
                dismiss()
            } label: {
                Text(status.hardRequirementsMet ? "Get started" : "Continue anyway")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Rows

    private var claudeRow: some View {
        SetupRow(mark: status.claudeOK ? .ok : .missing,
                 title: "Claude Code CLI",
                 detail: status.claudePath ?? "Not found on your PATH. Atelier needs the `claude` binary to spawn agents.") {
            if status.claudeOK {
                Button("Re-locate…") { locateClaude() }
                    .controlSize(.small)
            } else {
                Button("Installation guide") { NSWorkspace.shared.open(installDocsURL) }
                    .controlSize(.small)
                Button("Locate manually…") { locateClaude() }
                    .controlSize(.small)
            }
        }
    }

    private var gitRow: some View {
        SetupRow(mark: status.gitOK ? .ok : .missing,
                 title: "git",
                 detail: status.gitPath ?? "Not found. Install Apple's Command Line Tools to get git.") {
            if !status.gitOK {
                Button("Install Command Line Tools") { installCommandLineTools() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var authRow: some View {
        switch status.authSource {
        case .keychain:
            SetupRow(mark: .ok, title: "Authentication",
                     detail: "API key configured (stored in the macOS Keychain).") { EmptyView() }
        case .environment:
            SetupRow(mark: .ok, title: "Authentication",
                     detail: "Using ANTHROPIC_API_KEY from the launch environment.") { EmptyView() }
        case .subscription:
            SetupRow(mark: .info, title: "Authentication",
                     detail: "No API key set — Atelier will use your Claude subscription. Make sure you've signed in with `claude auth` in a terminal.") {
                Button("Copy “claude auth”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude auth", forType: .string)
                }
                .controlSize(.small)
                Button("Add an API key…") { openSettings() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private func locateClaude() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Locate the claude executable"
        panel.message = "Pick the `claude` binary (e.g. ~/.local/bin/claude)."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            ClaudeLocator.setOverridePath(url.path)
            status = PreflightService.check()
        }
    }

    private func installCommandLineTools() {
        // Triggers macOS's GUI installer for the Command Line Tools (user-consented).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()
    }
}

// MARK: - Row

private struct SetupRow<Actions: View>: View {
    enum Mark { case ok, missing, info }

    let mark: Mark
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    init(mark: Mark, title: String, detail: String, @ViewBuilder actions: () -> Actions) {
        self.mark = mark
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 15))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AtelierFont.callout.weight(.semibold))
                Text(detail)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var icon: String {
        switch mark {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch mark {
        case .ok: return Palette.success
        case .missing: return Palette.error
        case .info: return Palette.warning
        }
    }
}
