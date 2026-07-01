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

    /// Files below `targetPct`, worst first.
    func belowTarget(_ targetPct: Int) -> [FileCoverage] {
        files.filter { $0.rate * 100 < Double(targetPct) }.sorted { $0.rate < $1.rate }
    }

    // MARK: Discovery

    static let reportFileNames = [
        "coverage.cobertura.xml", "cobertura-coverage.xml", "coverage.xml",  // cobertura
        "lcov.info",                                                          // lcov
        "coverage-summary.json",                                             // json-summary
    ]
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
        if name.hasSuffix(".xml") { return parseCobertura(text) }
        return parseLcov(text)   // lcov.info / *.info
    }

    private static func newestReportFile(in dir: String) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                     options: []) else { return nil }
        var best: (path: String, date: Date)? = nil
        for case let url as URL in en {
            let comps = url.pathComponents
            if comps.contains(where: { prunedDirs.contains($0) }) { en.skipDescendants(); continue }
            guard reportFileNames.contains(url.lastPathComponent.lowercased()) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || date > best!.date { best = (url.path, date) }
        }
        return best?.path
    }

    // MARK: Parsers

    static func parseCobertura(_ xml: String) -> CoverageReport? {
        // Overall: the first `line-rate="…"` is on the root <coverage> element.
        guard let overall = firstDouble(in: xml, pattern: #"line-rate="([0-9.]+)""#) else { return nil }
        var files: [FileCoverage] = []
        // Per <class filename="…" … line-rate="…">
        let re = try? NSRegularExpression(pattern: #"<class\b[^>]*?filename="([^"]+)"[^>]*?line-rate="([0-9.]+)""#)
        if let re {
            let ns = xml as NSString
            for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
                let file = ns.substring(with: m.range(at: 1))
                if let rate = Double(ns.substring(with: m.range(at: 2))) {
                    files.append(FileCoverage(path: file, rate: rate))
                }
            }
        }
        return CoverageReport(lineRate: overall, files: files)
    }

    static func parseLcov(_ text: String) -> CoverageReport? {
        var files: [FileCoverage] = []
        var totalFound = 0, totalHit = 0
        var curFile: String? = nil
        var lf = 0, lh = 0
        var sawRecord = false
        func flush() {
            if let f = curFile, lf > 0 {
                files.append(FileCoverage(path: f, rate: Double(lh) / Double(lf)))
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
        return CoverageReport(lineRate: Double(totalHit) / Double(totalFound), files: files)
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
            if let p = pct(value) { files.append(FileCoverage(path: key, rate: p / 100.0)) }
        }
        return CoverageReport(lineRate: totalPct / 100.0, files: files)
    }

    private static func firstDouble(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Double(ns.substring(with: m.range(at: 1)))
    }
}
