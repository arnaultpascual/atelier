// SPDX-License-Identifier: MIT
import SwiftUI

/// Side-by-side BEFORE/AFTER modal for reviewing a Haiku-improved description.
/// Synchronised scroll across both panes, character/line counters, optional
/// line-level diff highlight.
struct ImproveReviewSheet: View {
    let original: String
    let improved: String
    let onApply: () -> Void
    let onDismiss: () -> Void

    @State private var highlightDiff: Bool = true
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider)
            HStack(spacing: 0) {
                pane(title: "BEFORE",
                     subtitle: meta(for: original),
                     text: original,
                     side: .before)
                Divider().background(Color.atelierDivider)
                pane(title: "AFTER",
                     subtitle: meta(for: improved),
                     text: improved,
                     side: .after)
            }
            Divider().background(Color.atelierDivider)
            footer
        }
        .frame(minWidth: 880, idealWidth: 980, minHeight: 560, idealHeight: 640)
        .background(Color.atelierBackground)
        .foregroundStyle(Color.atelierInk)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle().fill(Color.atelierAccentSoft).frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atelierAccent)
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
            VStack(alignment: .leading, spacing: 2) {
                Text("Improve description")
                    .font(AtelierFont.title)
                    .foregroundStyle(Color.atelierInk)
                Text("Haiku 4.5 rewrote your draft — review before applying.")
                    .font(AtelierFont.caption)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            Spacer()
            Toggle(isOn: $highlightDiff) {
                HStack(spacing: 4) {
                    Image(systemName: "highlighter").font(.system(size: 10))
                    Text("Highlight changes").font(AtelierFont.caption)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close without applying")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    // MARK: Panes

    private enum Side { case before, after }

    private func pane(title: String, subtitle: String, text: String, side: Side) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(side == .after ? Color.atelierAccent : Color.atelierInkSecondary)
                Spacer()
                Text(subtitle)
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierInkSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Rectangle()
                    .fill(side == .after
                          ? Color.atelierAccentSoft.opacity(0.4)
                          : Color.atelierSurface)
                    .ignoresSafeArea(edges: .horizontal)
            )

            ScrollView(.vertical) {
                if text.isEmpty {
                    Text(side == .before ? "(empty description)" : "(Haiku returned nothing)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.atelierInkSecondary.opacity(0.6))
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if highlightDiff {
                    DiffText(lines: diffLines(text: text, side: side))
                        .padding(20)
                } else {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.atelierInk)
                        .textSelection(.enabled)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.atelierBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Apply replaces your unsaved description. ⌘Z reverts in the editor.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Spacer()
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(action: onApply) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    Text("Apply").font(.system(.callout).weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color.atelierAccent, in: RoundedRectangle(cornerRadius: AtelierCorner.control))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func meta(for s: String) -> String {
        let chars = s.count
        let lines = s.isEmpty ? 0 : s.components(separatedBy: "\n").count
        return "\(chars) chars · \(lines) line\(lines == 1 ? "" : "s")"
    }

    /// Compute line-level diff classes for the given side, comparing original vs improved.
    private func diffLines(text: String, side: Side) -> [DiffText.Line] {
        let beforeLines = original.components(separatedBy: "\n")
        let afterLines = improved.components(separatedBy: "\n")
        let beforeSet = Set(beforeLines)
        let afterSet = Set(afterLines)

        let lines = text.components(separatedBy: "\n")
        return lines.map { line in
            switch side {
            case .before:
                if afterSet.contains(line) {
                    return .init(text: line, kind: .unchanged)
                } else {
                    return .init(text: line, kind: .removed)
                }
            case .after:
                if beforeSet.contains(line) {
                    return .init(text: line, kind: .unchanged)
                } else {
                    return .init(text: line, kind: .added)
                }
            }
        }
    }
}

// MARK: - Diff text renderer

private struct DiffText: View {
    struct Line: Hashable {
        let text: String
        let kind: Kind
        enum Kind { case unchanged, added, removed }
    }

    let lines: [Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 6) {
            Text(symbol(for: line.kind))
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(symbolColor(for: line.kind))
                .frame(width: 12, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(textColor(for: line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(rowBackground(for: line.kind))
    }

    private func symbol(for kind: Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .unchanged: return " "
        }
    }
    private func symbolColor(for kind: Line.Kind) -> Color {
        switch kind {
        case .added: return Palette.success
        case .removed: return Palette.error
        case .unchanged: return .clear
        }
    }
    private func textColor(for kind: Line.Kind) -> Color {
        switch kind {
        case .added: return Color.atelierInk
        case .removed: return Color.atelierInk.opacity(0.55)
        case .unchanged: return Color.atelierInk.opacity(0.85)
        }
    }
    private func rowBackground(for kind: Line.Kind) -> Color {
        switch kind {
        case .added: return Palette.success.opacity(0.10)
        case .removed: return Palette.error.opacity(0.08)
        case .unchanged: return .clear
        }
    }
}
