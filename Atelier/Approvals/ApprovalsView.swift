// SPDX-License-Identifier: MIT
import SwiftUI

/// Full-page approval queue. Replaces the modal Approval Inbox sheet — same
/// data, one row per pending approval, with a "Open session" link that opens
/// the task sheet for the worker that asked.
///
/// Resolved approvals stay visible briefly (their `purgeResolved` window) so
/// you can see what just cleared, then fall off.
struct ApprovalsView: View {
    @Bindable var queue: ApprovalQueue
    @Bindable var store: AppStore
    /// Called when the user clicks a card / "Open session" link.
    let onOpenTask: (_ taskId: String) -> Void

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 380, maximum: 540), spacing: 14)]

    var body: some View {
        ZStack {
            Color.atelierBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                trafficLightReserve
                header
                if queue.pending.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
    }

    private var trafficLightReserve: some View {
        Color.clear.frame(height: 16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Approvals")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("\(queue.pending.count) pending")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
                if queue.resolvedCount > 0 {
                    Text("· \(queue.resolvedCount) resolved")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
                }
                Spacer()
            }
            Text("Tool calls workers are pausing on until you decide. Click a card to open the session that asked.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            AtelierDivider()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(queue.pending) { approval in
                    ApprovalScreenCard(
                        approval: approval,
                        project: queue.project(forAgent: approval.agentId),
                        onOpenTask: {
                            if let id = approval.taskId { onOpenTask(id) }
                        },
                        onDecision: { decision in queue.resolve(id: approval.id, with: decision) },
                        onAlwaysAccept: { queue.alwaysAccept(toolName: approval.toolName, forAgent: approval.agentId) },
                        onPersistRule: { rule in
                            guard let project = queue.project(forAgent: approval.agentId) else { return }
                            try? queue.persistProjectRule(rule, project: project, agentId: approval.agentId)
                        }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 76, height: 76)
                Image(systemName: "bell")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.atelierAccent)
            }
            VStack(spacing: 4) {
                Text("Inbox is clear")
                    .font(AtelierFont.subtitle)
                    .foregroundStyle(Color.atelierInk)
                Text("Workers pause here when they want to run a tool that needs review.\nProfile defaults and project rules already handle the safe ones.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Card

private struct ApprovalScreenCard: View {
    let approval: PendingApproval
    let project: Project?
    let onOpenTask: () -> Void
    let onDecision: (ApprovalDecision) -> Void
    let onAlwaysAccept: () -> Void
    let onPersistRule: (PermissionRule) -> Void

    @State private var jsonExpanded = false
    @State private var respondingMode = false
    @State private var responseMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionLink
            headerRow
            summaryRow
            if jsonExpanded { jsonBlock }
            if respondingMode { respondBlock }
            actionBar
        }
        .padding(14)
        .background(Color.atelierAccentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: AtelierCorner.card))
        .overlay(
            RoundedRectangle(cornerRadius: AtelierCorner.card)
                .stroke(Color.atelierAccent.opacity(0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var sessionLink: some View {
        Button(action: onOpenTask) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .semibold))
                if let projectName = approval.projectName {
                    Text(projectName)
                        .font(AtelierFont.eyebrow)
                }
                if let taskId = approval.taskId {
                    Text(taskId)
                        .font(AtelierFont.captionMono)
                }
                Text("Open session")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                Spacer(minLength: 0)
                Text(approval.requestedAt.formatted(date: .omitted, time: .standard))
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            }
            .foregroundStyle(Color.atelierAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.atelierBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierAccent.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open the task sheet for the worker that asked.")
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(Color.atelierAccent)
                .font(.system(size: 11))
            Text(approval.toolName)
                .font(AtelierFont.callout.weight(.semibold))
                .foregroundStyle(Color.atelierInk)
            Spacer()
        }
    }

    private var summaryRow: some View {
        Text(approval.summaryLine)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Color.atelierInk)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.atelierBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
    }

    private var jsonBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(prettyInput)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.atelierInk)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
    }

    private var respondBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MESSAGE TO WORKER")
                .font(AtelierFont.eyebrow)
                .foregroundStyle(Color.atelierInkSecondary)
            TextEditor(text: $responseMessage)
                .font(.system(.callout))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 160)
                .padding(6)
                .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
            Text("Claude sees this as the deny reason and can re-plan.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                jsonExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: jsonExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                    Text(jsonExpanded ? "Hide JSON" : "Show JSON")
                        .font(AtelierFont.caption)
                }
                .foregroundStyle(Color.atelierInkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.atelierSurface, in: Capsule())
                .overlay(Capsule().stroke(Color.atelierDivider, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onDecision(.deny(message: "User declined this tool call."))
            } label: {
                Text("Deny")
                    .font(.system(.callout))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button {
                if respondingMode {
                    let msg = responseMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !msg.isEmpty else { return }
                    onDecision(.deny(message: msg))
                } else {
                    respondingMode = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: respondingMode ? "paperplane.fill" : "text.bubble")
                        .font(.system(size: 10))
                    Text(respondingMode ? "Send response" : "Respond")
                        .font(.system(.callout).weight(.medium))
                }
                .foregroundStyle(respondingMode ? .white : Color.atelierAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    respondingMode ? Color.atelierAccent : Color.atelierAccentSoft.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: AtelierCorner.control)
                )
            }
            .buttonStyle(.plain)
            .disabled(respondingMode && responseMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            acceptSplit
        }
    }

    private var acceptSplit: some View {
        HStack(spacing: 0) {
            Button {
                onDecision(.accept(updatedInput: nil))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Accept")
                        .font(.system(.callout).weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().frame(width: 1, height: 16).overlay(Color.white.opacity(0.25))

            Menu {
                Button {
                    onDecision(.accept(updatedInput: nil))
                    onAlwaysAccept()
                } label: {
                    Label("Always accept \(approval.toolName) for this run",
                          systemImage: "infinity")
                }
                if let projectName = project?.name {
                    Divider()
                    Button {
                        onDecision(.accept(updatedInput: nil))
                        onPersistRule(.init(
                            tool: approval.toolName,
                            pattern: nil,
                            behavior: .allow,
                            reason: "User-allowed \(approval.toolName) from inbox",
                            scope: .project
                        ))
                    } label: {
                        Label("Always accept \(approval.toolName) in \(projectName)",
                              systemImage: "folder.badge.plus")
                    }
                    if let candidate = patternCandidate {
                        Button {
                            onDecision(.accept(updatedInput: nil))
                            onPersistRule(.init(
                                tool: approval.toolName,
                                pattern: candidate.pattern,
                                behavior: .allow,
                                reason: "User-allowed exact pattern from inbox",
                                scope: .project
                            ))
                        } label: {
                            Label("Always accept \(approval.toolName) matching \(candidate.preview) in \(projectName)",
                                  systemImage: "wand.and.stars")
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
    }

    private var patternCandidate: (pattern: String, preview: String)? {
        guard let raw = PermissionRule.extractValue(toolName: approval.toolName, inputJSON: approval.inputJSON),
              !raw.isEmpty else { return nil }
        switch approval.toolName {
        case "Read", "Write", "Edit", "NotebookEdit":
            if let project = project, raw.hasPrefix(project.path) {
                let ext = (raw as NSString).pathExtension
                if !ext.isEmpty {
                    return ("$PROJECT/**/*.\(ext)", "*.\(ext)")
                }
                return ("$PROJECT/**", "anything in this project")
            }
            return (raw, (raw as NSString).lastPathComponent)
        case "Bash":
            let first = raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? raw
            return ("re:^\(first)( |$)", "`\(first) …`")
        case "Glob", "Grep":
            return (raw, raw)
        case "WebFetch":
            if let url = URL(string: raw), let host = url.host {
                return ("re:^https?://\(NSRegularExpression.escapedPattern(for: host))(/.*)?$", host)
            }
            return (raw, raw)
        default:
            return nil
        }
    }

    private var prettyInput: String {
        guard let data = approval.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let s = String(data: pretty, encoding: .utf8) else {
            return approval.inputJSON
        }
        return s
    }
}
