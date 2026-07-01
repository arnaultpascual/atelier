// SPDX-License-Identifier: MIT
//
// Pure, testable markdown model for the living brief/spec. The MCP `brief_*` and
// `spec_record_finding` tools apply STRUCTURED mutations here instead of letting
// the worker freeform-edit brief.md, keeping the document canonical + auditable.
// The app owns brief.md (single writer); this is applied app-side, then the file
// is written and the preview refreshed. No dependencies beyond Foundation.

import Foundation

struct BriefDocument: Equatable {
    struct Section: Equatable {
        var heading: String   // H2 text without "## "
        var body: String
    }

    /// Canonical H2 sections, in the order they should appear.
    static let canonicalOrder: [String] = [
        "Overview", "Requirements", "Acceptance Criteria",
        "Open Questions", "Decisions", "References", "Build Findings",
    ]

    /// Raw markdown before the first H2 (e.g. an H1 title). Preserved verbatim.
    private(set) var preamble: String
    /// Ordered sections.
    private(set) var sections: [Section]

    // MARK: Parse / render

    static func parse(_ text: String) -> BriefDocument {
        var preambleLines: [String] = []
        var sections: [Section] = []
        var currentHeading: String? = nil
        var currentBody: [String] = []

        func flush() {
            if let h = currentHeading {
                sections.append(Section(heading: h, body: currentBody.joined(separator: "\n").trimmedBlock()))
            }
            currentBody = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentHeading == nil {
                preambleLines.append(line)
            } else {
                currentBody.append(line)
            }
        }
        flush()
        return BriefDocument(preamble: preambleLines.joined(separator: "\n").trimmedBlock(),
                             sections: sections)
    }

    func rendered() -> String {
        var out: [String] = []
        if !preamble.isEmpty { out.append(preamble) }
        for s in sections {
            var block = "## \(s.heading)"
            if !s.body.isEmpty { block += "\n\n\(s.body)" }
            out.append(block)
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    // MARK: Section helpers

    private func canonicalRank(_ heading: String) -> Int? {
        Self.canonicalOrder.firstIndex { $0.caseInsensitiveCompare(heading) == .orderedSame }
    }
    private func indexOfSection(_ heading: String) -> Int? {
        sections.firstIndex { $0.heading.caseInsensitiveCompare(heading) == .orderedSame }
    }

    /// Returns the insertion index that keeps canonical sections in order, with
    /// non-canonical sections trailing in insertion order.
    private func insertionIndex(for heading: String) -> Int {
        guard let rank = canonicalRank(heading) else { return sections.count }  // freeform → end
        for (i, s) in sections.enumerated() {
            if let r = canonicalRank(s.heading), r > rank { return i }
            if canonicalRank(s.heading) == nil { return i }  // before trailing non-canonical
        }
        return sections.count
    }

    private mutating func ensureSection(_ heading: String) -> Int {
        if let i = indexOfSection(heading) { return i }
        let i = insertionIndex(for: heading)
        sections.insert(Section(heading: heading, body: ""), at: i)
        return i
    }

    /// Sets (replaces) a section's body, creating the section if needed.
    mutating func setSectionBody(_ heading: String, _ body: String) {
        let i = ensureSection(heading)
        sections[i].body = body.trimmedBlock()
    }

    /// Appends a markdown block to a section (blank line separated).
    mutating func appendBlock(to heading: String, _ md: String) {
        let i = ensureSection(heading)
        let block = md.trimmedBlock()
        sections[i].body = sections[i].body.isEmpty ? block
            : sections[i].body + "\n\n" + block
    }

    /// Appends a single bullet line to a section.
    mutating func appendBullet(to heading: String, _ line: String) {
        let i = ensureSection(heading)
        let bullet = line.hasPrefix("- ") ? line : "- \(line)"
        sections[i].body = sections[i].body.isEmpty ? bullet
            : sections[i].body + "\n" + bullet
    }

    // MARK: High-level brief mutations (one per MCP tool)

    mutating func setOverview(_ markdown: String) { setSectionBody("Overview", markdown) }

    mutating func appendSection(heading: String, markdown: String) {
        appendBlock(to: heading, markdown)
    }

    mutating func addRequirement(_ text: String, priority: String? = nil) {
        let tag = priority.map { "[\($0.uppercased())] " } ?? ""
        appendBullet(to: "Requirements", "\(tag)\(text)")
    }

    mutating func addAcceptanceCriterion(_ text: String) {
        appendBullet(to: "Acceptance Criteria", "[ ] \(text)")
    }

    mutating func addOpenQuestion(_ text: String) {
        appendBullet(to: "Open Questions", "[ ] \(text)")
    }

    /// Resolves the `index`-th (1-based) open question bullet. Returns false if
    /// there is no such question.
    @discardableResult
    mutating func resolveOpenQuestion(index: Int, answer: String) -> Bool {
        guard let sec = indexOfSection("Open Questions") else { return false }
        var lines = sections[sec].body.components(separatedBy: "\n")
        var count = 0
        for (i, line) in lines.enumerated() where line.hasPrefix("- ") {
            count += 1
            if count == index {
                var resolved = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
                if resolved == line { resolved = line }  // tolerate a non-checkbox bullet
                lines[i] = "\(resolved) — **A:** \(answer)"
                sections[sec].body = lines.joined(separator: "\n")
                return true
            }
        }
        return false
    }

    mutating func recordDecision(_ decision: String, rationale: String) {
        appendBullet(to: "Decisions", "**\(decision)** — \(rationale)")
    }

    mutating func attachReference(_ urlOrPath: String, note: String? = nil) {
        appendBullet(to: "References", note.map { "\(urlOrPath) — \($0)" } ?? urlOrPath)
    }

    /// D1: a discovered constraint + workaround, so other feature workers/reviewers see it.
    mutating func recordFinding(_ finding: String, impact: String? = nil, workaround: String? = nil) {
        var parts = ["**\(finding)**"]
        if let impact { parts.append("Impact: \(impact)") }
        if let workaround { parts.append("Workaround: \(workaround)") }
        appendBullet(to: "Build Findings", parts.joined(separator: " · "))
    }
}

private extension String {
    /// Trims leading/trailing blank lines (keeps interior formatting).
    func trimmedBlock() -> String {
        var lines = components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
