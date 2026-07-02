// SPDX-License-Identifier: MIT
//
// Multi-format coverage report parser (D3). Atelier historically parsed only
// .NET Cobertura XML; the MCP `coverage_get` / `coverage_uncovered` tools need a
// number across modes, so this reads whichever standard report a worktree has:
//   • Cobertura XML   — dotnet coverlet (coverage.cobertura.xml), python
//                        `coverage xml` (coverage.xml, cobertura format)
//   • LCOV            — node c8/nyc (lcov.info), swift `llvm-cov export -format=lcov`
//   • json-summary    — c8/nyc (coverage-summary.json)
// Pure Foundation, no app deps → fully unit-tested. Informational only; coverage
// is never a hard gate (soft 90% aim).

import Foundation

struct CoverageReport: Equatable {
    struct FileCoverage: Equatable { var path: String; var rate: Double }  // rate 0…1

    var lineRate: Double            // overall 0…1
    var files: [FileCoverage]

    var percent: Int { Int((lineRate * 100).rounded()) }

    /// Files below `targetPct`, worst first. Compares the ROUNDED percent so the
    /// filter agrees with the displayed per-file percent (no 89.5%-shown-as-90%-but-listed).
    func belowTarget(_ targetPct: Int) -> [FileCoverage] {
        files.filter { Int(($0.rate * 100).rounded()) < targetPct }.sorted { $0.rate < $1.rate }
    }

    /// Clamp a parsed rate into [0, 1] — some instrumentation emits LH > LF on
    /// generated/inlined lines, which would otherwise yield >100%.
    private static func clamp(_ r: Double) -> Double { min(1.0, max(0.0, r)) }

    // MARK: Discovery

    static let reportFileNames = [
        "coverage.cobertura.xml", "cobertura-coverage.xml", "coverage.xml",  // cobertura (dotnet, python coverage.py)
        "jacoco.xml", "jacocotestreport.xml",                                // jacoco (android / jvm)
        "lcov.info",                                                          // lcov (node, swift llvm)
        "coverage-summary.json",                                             // json-summary (node c8/nyc)
    ]
    // NB: ".build" (SwiftPM) is pruned but "build" is NOT — Android/Gradle JaCoCo
    // reports live under build/reports/jacoco/…, which must remain discoverable.
    private static let prunedDirs: Set<String> = ["bin", "obj", "node_modules", ".git", ".build", "DerivedData"]

    /// Finds the newest known coverage report under `dir` and parses it.
    static func find(in dir: String) -> CoverageReport? {
        guard let newest = newestReportFile(in: dir) else { return nil }
        return parseFile(at: newest)
    }

    static func parseFile(at path: String) -> CoverageReport? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".json") { return parseJsonSummary(text) }
        if name.hasSuffix(".xml") { return parseXML(text) }
        return parseLcov(text)   // lcov.info / *.info
    }

    /// Disambiguate the two XML dialects we support: Cobertura carries a
    /// `line-rate=` attribute; JaCoCo uses `<counter type="LINE" …>` elements.
    static func parseXML(_ xml: String) -> CoverageReport? {
        if xml.contains("line-rate=") { return parseCobertura(xml) }
        if xml.contains("type=\"LINE\"") { return parseJacoco(xml) }
        return parseCobertura(xml)   // best-effort
    }

    private static func newestReportFile(in dir: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                     options: []) else { return nil }
        var best: (path: String, date: Date)? = nil
        let baseDepth = URL(fileURLWithPath: dir).standardizedFileURL.pathComponents.count
        for case let url as URL in en {
            // Only prune components BELOW the base dir — a project whose own path
            // contains e.g. ".build" must not prune every report inside it.
            let relComps = url.standardizedFileURL.pathComponents.dropFirst(baseDepth)
            if relComps.contains(where: { prunedDirs.contains($0) }) { en.skipDescendants(); continue }
            guard reportFileNames.contains(url.lastPathComponent.lowercased()) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (url.path, date) }
        }
        return best?.path
    }

    // MARK: Parsers

    static func parseCobertura(_ xml: String) -> CoverageReport? {
        // Overall: anchor to the root <coverage …> element's line-rate; fall back
        // to the first line-rate anywhere only if the root has none.
        guard let overall = firstDouble(in: xml, pattern: #"<coverage\b[^>]*?line-rate="([0-9.]+)""#)
                ?? firstDouble(in: xml, pattern: #"line-rate="([0-9.]+)""#) else { return nil }
        var files: [FileCoverage] = []
        // Per <class …>: extract filename + line-rate order-independently.
        if let tagRe = try? NSRegularExpression(pattern: #"<class\b([^>]*)>"#) {
            let ns = xml as NSString
            for m in tagRe.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
                let attrs = ns.substring(with: m.range(at: 1))
                if let file = firstString(in: attrs, pattern: #"filename="([^"]+)""#),
                   let rate = firstDouble(in: attrs, pattern: #"line-rate="([0-9.]+)""#) {
                    files.append(FileCoverage(path: file, rate: clamp(rate)))
                }
            }
        }
        return CoverageReport(lineRate: clamp(overall), files: files)
    }

    /// JaCoCo XML (Android / JVM). Overall + per-file line coverage are derived
    /// from each `<sourcefile>`'s `<counter type="LINE" missed=.. covered=..>`,
    /// summed for the total (deterministic — no reliance on which root counter
    /// comes first). Attribute order is tolerated.
    static func parseJacoco(_ xml: String) -> CoverageReport? {
        var files: [FileCoverage] = []
        var totMissed = 0, totCovered = 0
        guard let sfRe = try? NSRegularExpression(
            pattern: #"<sourcefile\b[^>]*?name="([^"]+)"[^>]*>(.*?)</sourcefile>"#,
            options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = xml as NSString
        for m in sfRe.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            guard let (miss, cov) = jacocoLineCounter(body) else { continue }
            totMissed += miss; totCovered += cov
            let denom = miss + cov
            if denom > 0 { files.append(FileCoverage(path: name, rate: clamp(Double(cov) / Double(denom)))) }
        }
        let denom = totMissed + totCovered
        guard denom > 0 else { return nil }
        return CoverageReport(lineRate: clamp(Double(totCovered) / Double(denom)), files: files)
    }

    /// Extracts (missed, covered) from a JaCoCo `<counter type="LINE" …/>` inside
    /// the given fragment, tolerant of attribute order.
    private static func jacocoLineCounter(_ fragment: String) -> (missed: Int, covered: Int)? {
        guard let tag = firstString(in: fragment, pattern: #"(<counter\b[^>]*type="LINE"[^>]*/>)"#) else { return nil }
        guard let missed = firstDouble(in: tag, pattern: #"missed="([0-9]+)""#).map({ Int($0) }),
              let covered = firstDouble(in: tag, pattern: #"covered="([0-9]+)""#).map({ Int($0) }) else { return nil }
        return (missed, covered)
    }

    static func parseLcov(_ text: String) -> CoverageReport? {
        var files: [FileCoverage] = []
        var totalFound = 0, totalHit = 0
        var curFile: String? = nil
        var lf = 0, lh = 0
        var sawRecord = false
        func flush() {
            if let f = curFile, lf > 0 {
                files.append(FileCoverage(path: f, rate: clamp(Double(lh) / Double(lf))))
                totalFound += lf; totalHit += lh
            }
            curFile = nil; lf = 0; lh = 0
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") { flush(); curFile = String(line.dropFirst(3)); sawRecord = true }
            else if line.hasPrefix("LF:") { lf = Int(line.dropFirst(3)) ?? 0 }
            else if line.hasPrefix("LH:") { lh = Int(line.dropFirst(3)) ?? 0 }
            else if line == "end_of_record" { flush() }
        }
        flush()
        guard sawRecord, totalFound > 0 else { return nil }
        return CoverageReport(lineRate: clamp(Double(totalHit) / Double(totalFound)), files: files)
    }

    static func parseJsonSummary(_ json: String) -> CoverageReport? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func pct(_ any: Any?) -> Double? {
            (((any as? [String: Any])?["lines"]) as? [String: Any])?["pct"] as? Double
        }
        guard let totalPct = pct(obj["total"]) else { return nil }
        var files: [FileCoverage] = []
        for (key, value) in obj where key != "total" {
            if let p = pct(value) { files.append(FileCoverage(path: key, rate: clamp(p / 100.0))) }
        }
        return CoverageReport(lineRate: clamp(totalPct / 100.0), files: files)
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        firstString(in: text, pattern: pattern).flatMap(Double.init)
    }
    private static func firstString(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
