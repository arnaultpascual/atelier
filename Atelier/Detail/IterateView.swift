// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// Full-page conversation view for iterating with a prior worker session.
///
/// Replaces the task sheet body when the user clicks "Iterate" from the Review
/// section. Loads the prior conversation from claude's persisted JSONL,
/// appends live events from each new turn (spawned with `--resume <sessionId>`),
/// and lets the user type follow-up messages.
struct IterateView: View {
    @Bindable var store: AppStore
    @Bindable var spawner: TaskSpawner
    @Bindable var server: ApprovalServer
    @Bindable var approvalQueue: ApprovalQueue
    let task: AtelierTask
    let project: Project
    let onExit: () -> Void

    @State private var priorAgent: Agent?
    @State private var historyEvents: [StreamEvent] = []
    @State private var historyLoaded: Bool = false
    @State private var draft: String = ""
    @State private var sendError: String?

    private var liveRun: ActiveRun? { spawner.activeRun(for: task.id) }
    private var isWorking: Bool {
        guard let r = liveRun else { return false }
        return !r.agent.status.isTerminal
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            conversationScroll
            Divider().background(Color.atelierDivider).opacity(0.6)
            footer
        }
        .background(Color.atelierBackground)
        .task { await load() }
        .onChange(of: liveRun?.agent.status) { _, _ in
            // When a turn completes the agent row gets a fresh sessionId; reload prior.
            Task { await refreshPrior() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onExit) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(AtelierFont.callout)
                }
                .foregroundStyle(Color.atelierInkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.atelierSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 2) {
                Text("Iterate")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierAccent)
                Text(task.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let agent = priorAgent {
                    Text("worktree-\(task.id)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                    if let sid = agent.sessionId {
                        Text("session \(String(sid.prefix(8)))…")
                            .font(AtelierFont.captionMono)
                            .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                    }
                }
                if let r = liveRun, r.state.totalCostUsd > 0 {
                    Text(String(format: "$%.4f", r.state.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Conversation

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(combinedEvents) { event in
                        EventCardRow(event: event)
                            .id(event.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isWorking {
                        workingIndicator
                            .id("working")
                    }
                    if combinedEvents.isEmpty && historyLoaded {
                        emptyHint
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: combinedEvents.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if isWorking {
                        proxy.scrollTo("working", anchor: .bottom)
                    } else if let lastId = combinedEvents.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var combinedEvents: [StreamEvent] {
        var out = historyEvents
        if let live = liveRun?.state.events {
            // Avoid duplicates by id; live events are post-history.
            let known = Set(out.map { $0.id })
            out.append(contentsOf: live.filter { !known.contains($0.id) })
        }
        return out
    }

    private var workingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(liveRun?.statusHint.isEmpty == false ? liveRun!.statusHint : "claude is working…")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
        }
        .padding(12)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.5))
            Text("No prior conversation found for this task.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Footer / input

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Text(sendError)
                    .font(AtelierFont.caption)
                    .foregroundStyle(Palette.error)
            }
            HStack(alignment: .bottom, spacing: 10) {
                inputField
                sendButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.atelierBackground)
    }

    private var inputField: some View {
        TextEditor(text: $draft)
            .font(.system(.body, design: .default))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 56, maxHeight: 160)
            .padding(10)
            .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            .overlay(
                RoundedRectangle(cornerRadius: AtelierCorner.control)
                    .stroke(Color.atelierDivider, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(isWorking ? "Waiting for claude to finish this turn…" : "Reply, ask, or steer claude. Sent with --resume.")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }
            }
            .disabled(isWorking || canIterate == false)
    }

    private var sendButton: some View {
        Button(action: send) {
            HStack(spacing: 5) {
                if isWorking {
                    ProgressView().controlSize(.small).colorInvert()
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 11))
                }
                Text(isWorking ? "Running…" : "Send")
                    .font(.system(.callout).weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                sendIsReady ? Color.atelierAccent : Color.atelierInkSecondary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: AtelierCorner.control)
            )
        }
        .buttonStyle(.plain)
        .disabled(!sendIsReady)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(canIterate ? "⌘↩ to send. Spawns claude --resume on this session." : "Need a prior session with a recorded sessionId.")
    }

    private var sendIsReady: Bool {
        !isWorking
            && canIterate
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canIterate: Bool {
        guard let agent = priorAgent else { return false }
        guard let sid = agent.sessionId, !sid.isEmpty else { return false }
        guard !agent.worktreePath.isEmpty,
              FileManager.default.fileExists(atPath: agent.worktreePath) else { return false }
        return true
    }

    // MARK: Actions

    private func load() async {
        await refreshPrior()
        loadHistory()
    }

    private func refreshPrior() async {
        let agents = (try? await store.agentsForTask(task.id)) ?? []
        // Pick the most recently ended agent that has a sessionId.
        priorAgent = agents.first(where: { $0.sessionId != nil }) ?? agents.first
    }

    private func loadHistory() {
        guard let agent = priorAgent, let sid = agent.sessionId,
              !agent.worktreePath.isEmpty else {
            historyLoaded = true
            return
        }
        if let events = SessionReader.loadEvents(cwd: agent.worktreePath, sessionId: sid) {
            historyEvents = events
        }
        historyLoaded = true
    }

    private func send() {
        guard sendIsReady, let agent = priorAgent else { return }
        let msg = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        sendError = nil
        spawner.iterate(
            task: task,
            project: project,
            priorAgent: agent,
            message: msg,
            apiKey: APIKeyResolver.resolve(),
            store: store,
            server: server,
            approvalQueue: approvalQueue
        )
        draft = ""
    }
}
