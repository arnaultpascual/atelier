// SPDX-License-Identifier: MIT
import SwiftUI

/// Compact card rendering for one StreamEvent — reused by the live agent view and
/// the review-state conversation transcript.
struct EventCardRow: View {
    let event: StreamEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                Text(event.kind.displayLabel)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(accent)
                Spacer()
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
            }
            summary
        }
        .padding(10)
        .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.atelierDivider.opacity(0.6), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summary: some View {
        switch event.kind {
        case .system(let subtype, _, let model):
            VStack(alignment: .leading, spacing: 2) {
                if let subtype {
                    Text("subtype: \(subtype)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                if let model {
                    Text("model: \(model)")
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
            }
        case .assistant(let text, let hasThinking, let toolUses):
            VStack(alignment: .leading, spacing: 6) {
                if hasThinking {
                    Label("thinking…", systemImage: "brain")
                        .font(AtelierFont.caption)
                        .foregroundStyle(Color.atelierInkSecondary)
                }
                if let text {
                    MarkdownView(source: text, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(toolUses, id: \.id) { use in
                    EventToolUsePill(use: use)
                }
            }
        case .user(let results):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(results, id: \.toolUseId) { r in
                    Text(r.textSummary)
                        .font(AtelierFont.captionMono)
                        .foregroundStyle(r.isError ? Palette.error : Color.atelierInk.opacity(0.85))
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .result(let subtype, let cost, _, let isError):
            HStack(spacing: 10) {
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
            }
        case .streamEvent(let t):
            Text("Δ \(t ?? "?")")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
        case .rateLimit(let msg):
            Label(msg ?? "rate limit", systemImage: "hourglass")
                .font(AtelierFont.caption)
                .foregroundStyle(Palette.warning)
        case .malformed(let reason):
            Text(reason).font(AtelierFont.caption).foregroundStyle(Palette.error)
        case .unknown(let t):
            Text("Unhandled: \(t ?? "?")").font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
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

struct EventToolUsePill: View {
    let use: StreamEvent.ToolUse

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9))
                .foregroundStyle(Color.atelierAccent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(use.name)
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
                Text(use.oneLineSummary)
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
