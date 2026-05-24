// SPDX-License-Identifier: MIT
import SwiftUI

/// Renders a markdown string as styled SwiftUI blocks (headings, code fences,
/// bullet lists, blockquotes, paragraphs with inline emphasis/links).
///
/// Shared rendering surface used by the worker conversation panel in Review
/// and by the in-app file preview. Handles only the subset of markdown that
/// Claude actually produces in assistant turns.
struct MarkdownView: View {
    let source: String
    /// When true, the renderer uses tighter spacing suitable for chat-style
    /// previews. When false (default), it uses comfortable reading spacing.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MarkdownParser.parse(source).enumerated()), id: \.offset) { _, block in
                block.view(compact: compact)
            }
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(lang: String, body: String)
    case quote(String)
    case bulletList(items: [String])

    @ViewBuilder
    func view(compact: Bool) -> some View {
        switch self {
        case .heading(let level, let text):
            MarkdownHeading(level: level, text: text, compact: compact)
        case .paragraph(let text):
            InlineMarkdownText(source: text)
                .font(compact ? .system(.callout) : .system(.body))
                .foregroundStyle(Color.atelierInk)
                .lineSpacing(compact ? 2 : 3)
                .padding(.vertical, compact ? 3 : 6)
                .textSelection(.enabled)
        case .codeBlock(_, let body):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(.system(compact ? .caption : .callout, design: .monospaced))
                    .foregroundStyle(Color.atelierInk)
                    .textSelection(.enabled)
                    .padding(compact ? 8 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.atelierSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.atelierDivider, lineWidth: 1))
            .padding(.vertical, compact ? 4 : 8)
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.atelierAccent)
                    .frame(width: 3)
                InlineMarkdownText(source: text)
                    .font(compact ? .system(.callout, design: .serif).italic() : .system(.body, design: .serif).italic())
                    .foregroundStyle(Color.atelierInkSecondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, compact ? 3 : 6)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(Color.atelierAccent)
                        InlineMarkdownText(source: item)
                            .font(compact ? .system(.callout) : .system(.body))
                            .foregroundStyle(Color.atelierInk)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, compact ? 2 : 4)
        }
    }
}

private struct MarkdownHeading: View {
    let level: Int
    let text: String
    let compact: Bool

    var body: some View {
        let font: Font = {
            if compact {
                switch level {
                case 1: return .system(.title3, design: .serif).weight(.bold)
                case 2: return .system(.headline, design: .serif).weight(.semibold)
                case 3: return .system(.subheadline, design: .default).weight(.semibold)
                default: return .system(.subheadline, design: .default).weight(.medium)
                }
            } else {
                switch level {
                case 1: return .system(.largeTitle, design: .serif).weight(.bold)
                case 2: return .system(.title, design: .serif).weight(.semibold)
                case 3: return .system(.title2, design: .serif).weight(.semibold)
                case 4: return .system(.title3, design: .default).weight(.semibold)
                case 5: return .system(.headline, design: .default)
                default: return .system(.subheadline, design: .default).weight(.semibold)
                }
            }
        }()
        InlineMarkdownText(source: text)
            .font(font)
            .foregroundStyle(Color.atelierInk)
            .padding(.top, compact ? (level <= 2 ? 8 : 5) : (level <= 2 ? 18 : 12))
            .padding(.bottom, compact ? 3 : 6)
    }
}

struct InlineMarkdownText: View {
    let source: String
    var body: some View {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var idx = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                out.append(.paragraph(paragraphBuffer.joined(separator: " ")))
                paragraphBuffer.removeAll()
            }
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                idx += 1
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3))
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count && !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[idx])
                    idx += 1
                }
                if idx < lines.count { idx += 1 }
                out.append(.codeBlock(lang: lang, body: codeLines.joined(separator: "\n")))
                continue
            }
            if let level = headingLevel(of: trimmed) {
                flushParagraph()
                let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append(.heading(level: level, text: content))
                idx += 1
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                var quoteLines: [String] = [String(trimmed.dropFirst(2))]
                idx += 1
                while idx < lines.count {
                    let q = lines[idx].trimmingCharacters(in: .whitespaces)
                    if q.hasPrefix("> ") {
                        quoteLines.append(String(q.dropFirst(2)))
                        idx += 1
                    } else { break }
                }
                out.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                var items: [String] = [String(trimmed.dropFirst(2))]
                idx += 1
                while idx < lines.count {
                    let l = lines[idx].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") || l.hasPrefix("* ") {
                        items.append(String(l.dropFirst(2)))
                        idx += 1
                    } else { break }
                }
                out.append(.bulletList(items: items))
                continue
            }
            paragraphBuffer.append(trimmed)
            idx += 1
        }
        flushParagraph()
        return out
    }

    private static func headingLevel(of line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        var count = 0
        for char in line {
            if char == "#" { count += 1 } else { break }
        }
        if count > 6 { return nil }
        let afterHashes = line.dropFirst(count)
        guard afterHashes.first == " " else { return nil }
        return count
    }
}
