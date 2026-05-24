// SPDX-License-Identifier: MIT
import SwiftUI

struct ContentView: View {
    @Bindable var state: AgentState
    @Bindable var server: ApprovalServer
    @Bindable var orchestrator: Orchestrator

    var body: some View {
        ZStack(alignment: .top) {
            Color.atelierBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar(state: state, server: server, orchestrator: orchestrator)
                Divider().background(Color.atelierDivider)
                ControlsBar(state: state, server: server, orchestrator: orchestrator)
                Divider().background(Color.atelierDivider)
                TimelineList(events: state.events)
                Divider().background(Color.atelierDivider)
                StatusFooter(state: state, server: server, orchestrator: orchestrator)
            }
        }
        .foregroundStyle(Color.atelierInk)
        .tint(Color.atelierAccent)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Bindable var state: AgentState
    @Bindable var server: ApprovalServer
    @Bindable var orchestrator: Orchestrator

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Atelier")
                        .font(AtelierFont.title)
                        .foregroundStyle(Color.atelierInk)
                    Text("Quick Spawn")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.atelierAccentSoft, in: Capsule())
                }
                Text("Fire a single ad-hoc claude worker — no project or task required")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            serverBadge
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var serverBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(server.helperReady ? Palette.success : Palette.stoneLight)
                .frame(width: 6, height: 6)
            Text(server.helperReady ? "MCP · helper" : "MCP · missing")
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.atelierSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
    }
}

// MARK: - Controls

private struct ControlsBar: View {
    @Bindable var state: AgentState
    @Bindable var server: ApprovalServer
    @Bindable var orchestrator: Orchestrator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Row 1: API key + model picker + partial stream toggle
            HStack(spacing: 12) {
                FieldLabel("Anthropic key")
                SecureField("blank → Claude Code subscription (Pro / Max / Enterprise)",
                            text: $orchestrator.apiKey)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                Picker("", selection: $orchestrator.selectedModelId) {
                    ForEach(Orchestrator.models, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
                Toggle("Stream partials", isOn: $orchestrator.includePartialMessages)
                    .toggleStyle(.checkbox)
                    .font(AtelierFont.caption)
                    .help("Pass --include-partial-messages to claude. Token-by-token streaming, noisier UI.")
            }

            if let warning = orchestrator.selectedModel.warning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    Text(warning)
                }
                .font(AtelierFont.caption)
                .foregroundStyle(Palette.warning)
            }

            // Row 2: cwd
            HStack(spacing: 10) {
                FieldLabel("cwd")
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .imageScale(.small)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(orchestrator.workingDirectory)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                Button("Choose…", action: pickWorkingDirectory)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            // Row 3: prompt + spawn
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("prompt")
                    TextField("", text: $orchestrator.prompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.control).stroke(Color.atelierDivider, lineWidth: 1))
                }
                .frame(maxWidth: .infinity)

                Button(action: spawn) {
                    HStack(spacing: 6) {
                        if orchestrator.isSpawnInFlight {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Spawn")
                            .font(.system(.body, design: .default).weight(.semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
                    .opacity(orchestrator.canSpawn(server: server) && !orchestrator.isSpawnInFlight ? 1.0 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!orchestrator.canSpawn(server: server) || orchestrator.isSpawnInFlight)
                .keyboardShortcut(.return, modifiers: [.command])
                .padding(.top, 18)
            }

            if orchestrator.claudePathResolved == nil {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.diamond.fill").imageScale(.small)
                    Text("`claude` executable not found. Install Claude Code so it lands at `~/.local/bin/claude` or `/opt/homebrew/bin/claude`.")
                }
                .font(AtelierFont.caption)
                .foregroundStyle(Palette.error)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func spawn() {
        Task { await orchestrator.spawn(state: state, server: server) }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose working directory for the Atelier worker"
        panel.message = "claude will run with its cwd set to the folder you pick."
        panel.directoryURL = URL(fileURLWithPath: orchestrator.workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            orchestrator.workingDirectory = url.path
        }
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(AtelierFont.eyebrow)
            .foregroundStyle(Color.atelierInkSecondary)
            .frame(width: 86, alignment: .trailing)
    }
}

// MARK: - Timeline

private struct TimelineList: View {
    let events: [StreamEvent]

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyTimelineView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(events) { event in
                                EventCard(event: event).id(event.id)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                    }
                    .onChange(of: events.count) { _, _ in
                        if let last = events.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyTimelineView: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.atelierAccentSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: "scroll")
                    .imageScale(.large)
                    .foregroundStyle(Color.atelierAccent)
            }
            VStack(spacing: 4) {
                Text("No events yet")
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                Text("Set your prompt, optionally pick a working directory,\nthen hit Spawn (⌘↩) to launch a worker.")
                    .multilineTextAlignment(.center)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EventCard: View {
    let event: StreamEvent

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent strip
            Rectangle()
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon)
                        .imageScale(.small)
                        .foregroundStyle(accent)
                    Text(event.kind.displayLabel)
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(accent)
                    Spacer()
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                summary
                DisclosureGroup {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(event.prettyJSON)
                            .font(AtelierFont.captionMono)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Raw payload")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            .padding(14)
        }
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(RoundedRectangle(cornerRadius: AtelierCorner.card).stroke(Color.atelierDivider, lineWidth: 1))
    }

    @ViewBuilder
    private var summary: some View {
        switch event.kind {
        case .system(let subtype, let session, let model):
            VStack(alignment: .leading, spacing: 3) {
                if let subtype { metaLine(key: "subtype", value: subtype) }
                if let model { metaLine(key: "model", value: model) }
                if let session { metaLine(key: "session", value: session) }
            }
        case .assistant(let text, let hasThinking, let toolUses):
            VStack(alignment: .leading, spacing: 6) {
                if hasThinking {
                    HStack(spacing: 4) {
                        Image(systemName: "brain").imageScale(.small)
                        Text("thinking block omitted")
                    }
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                }
                if let text {
                    Text(text)
                        .font(AtelierFont.body)
                        .foregroundStyle(Color.atelierInk)
                        .textSelection(.enabled)
                }
                if !toolUses.isEmpty {
                    ForEach(toolUses, id: \.id) { use in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver").imageScale(.small)
                            Text(use.name)
                                .font(AtelierFont.captionMono.weight(.semibold))
                            Text(use.inputJSON)
                                .font(AtelierFont.captionMono)
                                .foregroundStyle(Color.atelierInkSecondary)
                                .lineLimit(2)
                        }
                        .foregroundStyle(Color.atelierAccent)
                    }
                }
            }
        case .user(let results):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(results, id: \.toolUseId) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(r.toolUseId.prefix(8)))
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(Color.atelierInkSecondary)
                        Text(r.textSummary)
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(r.isError ? Palette.error : Color.atelierInk)
                            .lineLimit(4)
                    }
                }
            }
        case .result(let subtype, let cost, let usage, let isError):
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let subtype {
                    Text(subtype)
                        .font(AtelierFont.caption.weight(.semibold))
                        .foregroundStyle(isError ? Palette.error : Palette.success)
                }
                if let cost {
                    Text(String(format: "$%.4f", cost))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
                if let u = usage {
                    Text("in:\(u.inputTokens)  out:\(u.outputTokens)  cache_r:\(u.cacheReadTokens)  cache_w:\(u.cacheCreationTokens)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
        case .streamEvent(let t):
            Text("Δ \(t ?? "?")")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        case .rateLimit(let message):
            HStack(spacing: 6) {
                Image(systemName: "hourglass").imageScale(.small)
                Text(message ?? "rate limit notice")
                    .font(AtelierFont.caption)
            }
            .foregroundStyle(Palette.warning)
        case .malformed(let reason):
            Text(reason)
                .font(AtelierFont.caption)
                .foregroundStyle(Palette.error)
        case .unknown(let t):
            Text("Unhandled type: \(t ?? "nil")")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
    }

    private func metaLine(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInkSecondary)
            Text(value)
                .font(AtelierFont.captionMono)
                .foregroundStyle(Color.atelierInk)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch event.kind {
        case .system: return "gearshape"
        case .assistant: return "bubble.left"
        case .user: return "wrench.and.screwdriver"
        case .result(_, _, _, let isError): return isError ? "exclamationmark.octagon" : "checkmark.circle"
        case .streamEvent: return "dot.radiowaves.left.and.right"
        case .rateLimit: return "hourglass"
        case .malformed: return "exclamationmark.octagon"
        case .unknown: return "questionmark.circle"
        }
    }

    private var accent: Color {
        switch event.kind {
        case .system: return Color.atelierInkSecondary
        case .assistant: return Color.atelierAccent
        case .user: return Palette.claudeOrangeMuted
        case .result(_, _, _, let isError): return isError ? Palette.error : Palette.success
        case .streamEvent: return Palette.stoneLight
        case .rateLimit: return Palette.warning
        case .malformed: return Palette.error
        case .unknown: return Color.atelierInkSecondary
        }
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    let state: AgentState
    let server: ApprovalServer
    let orchestrator: Orchestrator

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                statusBadge
                Divider().frame(height: 14)
                HStack(spacing: 4) {
                    Text("Cost")
                        .font(AtelierFont.eyebrow)
                        .foregroundStyle(Color.atelierInkSecondary)
                    Text(String(format: "$%.4f", state.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
                .help("total_cost_usd from the worker's result event (subscription mode shows the API-equivalent figure)")
                Text("in:\(state.inputTokens) · out:\(state.outputTokens) · cache_r:\(state.cacheReadTokens) · cache_w:\(state.cacheCreationTokens)")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer()
                if !state.approvalHistory.isEmpty {
                    Text("\(state.approvalHistory.count) approval\(state.approvalHistory.count > 1 ? "s" : "") auto-allowed")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.success)
                }
                if let model = state.resolvedModel {
                    Text(model)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)

            if case .failed = state.status, !state.stderrLines.isEmpty {
                stderrPane
            }
        }
        .background(Color.atelierSurface)
    }

    private var statusBadge: some View {
        let (label, color, dot) = badgeInfo
        return HStack(spacing: 6) {
            Image(systemName: dot)
                .imageScale(.small)
                .foregroundStyle(color)
            Text(label)
                .font(AtelierFont.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private var badgeInfo: (String, Color, String) {
        switch state.status {
        case .idle: return ("Idle", Color.atelierInkSecondary, "moon.zzz")
        case .starting: return ("Starting", Palette.warning, "hourglass")
        case .running: return ("Running", Color.atelierAccent, "play.fill")
        case .awaitingApproval: return ("Awaiting", Palette.warning, "hand.raised")
        case .completed: return ("Completed", Palette.success, "checkmark.circle")
        case .failed(let reason): return ("Failed — \(reason)", Palette.error, "exclamationmark.octagon")
        }
    }

    private var stderrPane: some View {
        DisclosureGroup {
            ScrollView(.vertical) {
                Text(state.stderrLines.suffix(40).joined(separator: "\n"))
                    .font(AtelierFont.captionMono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
            }
            .frame(maxHeight: 160)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble").imageScale(.small)
                Text("worker stderr — \(state.stderrLines.count) line\(state.stderrLines.count > 1 ? "s" : "")")
                    .font(AtelierFont.caption.weight(.semibold))
            }
            .foregroundStyle(Palette.error)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }
}
