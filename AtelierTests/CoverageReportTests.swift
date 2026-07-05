// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class CoverageReportTests: XCTestCase {

    func testParseCoberturaOverallAndPerFile() {
        let xml = """
        <?xml version="1.0"?>
        <coverage line-rate="0.82" branch-rate="0.7" version="1.9">
          <packages>
            <package name="p" line-rate="0.82">
              <classes>
                <class name="A" filename="src/A.swift" line-rate="0.95"></class>
                <class name="B" filename="src/B.swift" line-rate="0.50"></class>
              </classes>
            </package>
          </packages>
        </coverage>
        """
        let r = CoverageReport.parseCobertura(xml)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.percent, 82)
        XCTAssertEqual(r?.files.count, 2)
        XCTAssertEqual(r?.files.first { $0.path == "src/B.swift" }?.rate, 0.5)
        XCTAssertEqual(r?.belowTarget(90).map { $0.path }, ["src/B.swift"])
    }

    func testParseLcov() {
        let lcov = """
        SF:/repo/src/a.js
        DA:1,1
        LF:10
        LH:9
        end_of_record
        SF:/repo/src/b.js
        LF:10
        LH:1
        end_of_record
        """
        let r = CoverageReport.parseLcov(lcov)
        XCTAssertNotNil(r)
        // total hit 10 / found 20 = 0.5
        XCTAssertEqual(r?.lineRate, 0.5)
        XCTAssertEqual(r?.files.count, 2)
        XCTAssertEqual(r?.files.first { $0.path == "/repo/src/b.js" }?.rate, 0.1)
    }

    func testParseJsonSummary() {
        let json = """
        {
          "total": { "lines": { "total": 100, "covered": 73, "pct": 73.0 } },
          "/repo/x.ts": { "lines": { "pct": 40.0 } },
          "/repo/y.ts": { "lines": { "pct": 95.0 } }
        }
        """
        let r = CoverageReport.parseJsonSummary(json)
        XCTAssertEqual(r?.percent, 73)
        XCTAssertEqual(r?.belowTarget(90).map { $0.path }, ["/repo/x.ts"])
    }

    func testParseJacocoOverallAndPerFile() {
        let xml = """
        <?xml version="1.0"?>
        <report name="app">
          <package name="com/x">
            <sourcefile name="A.kt">
              <counter type="INSTRUCTION" missed="10" covered="90"/>
              <counter type="LINE" missed="1" covered="9"/>
            </sourcefile>
            <sourcefile name="B.kt">
              <counter type="LINE" missed="8" covered="2"/>
            </sourcefile>
          </package>
          <counter type="LINE" missed="9" covered="11"/>
        </report>
        """
        let r = CoverageReport.parseJacoco(xml)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.percent, 55)          // covered 11 / found 20
        XCTAssertEqual(r?.files.count, 2)
        XCTAssertEqual(r?.files.first { $0.path == "A.kt" }?.rate, 0.9)
        XCTAssertEqual(r?.belowTarget(90).map { $0.path }, ["B.kt"])  // A is 90% (not below); B is 20%
    }

    func testParseXMLRoutesJacocoVsCobertura() {
        XCTAssertEqual(CoverageReport.parseXML(#"<coverage line-rate="0.42"></coverage>"#)?.percent, 42)
        let jacoco = #"<report><sourcefile name="A"><counter type="LINE" missed="1" covered="1"/></sourcefile></report>"#
        XCTAssertEqual(CoverageReport.parseXML(jacoco)?.percent, 50)
    }

    func testFindPicksJacocoUnderGradleBuildDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("app-\(UUID().uuidString)")
        let reportDir = base.appendingPathComponent("build/reports/jacoco/test")   // "build" is NOT pruned
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let jacoco = #"<report><sourcefile name="A.kt"><counter type="LINE" missed="1" covered="3"/></sourcefile></report>"#
        try jacoco.write(to: reportDir.appendingPathComponent("jacocoTestReport.xml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CoverageReport.find(in: base.path)?.percent, 75)
    }

    func testReportInsideVenvIsPruned() throws {
        // A stale/foreign coverage report inside a venv must not be picked as newest.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cov-\(UUID().uuidString)")
        let venv = base.appendingPathComponent("venv/lib/site-packages")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try #"<coverage line-rate="0.99"></coverage>"#
            .write(to: venv.appendingPathComponent("coverage.xml"), atomically: true, encoding: .utf8)
        XCTAssertNil(CoverageReport.find(in: base.path))   // only report is under venv → ignored
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(CoverageReport.parseCobertura("<coverage>no rate</coverage>"))
        XCTAssertNil(CoverageReport.parseLcov("garbage"))
        XCTAssertNil(CoverageReport.parseJsonSummary("{}"))
    }

    func testLcovClampsRateWhenHitExceedsFound() {
        // Some instrumentation emits LH > LF on generated lines → must clamp to 100%.
        let r = CoverageReport.parseLcov("SF:/x.js\nLF:5\nLH:8\nend_of_record")
        XCTAssertEqual(r?.percent, 100)
        XCTAssertEqual(r?.files.first?.rate, 1.0)
    }

    func testCoberturaReversedAttributeOrder() {
        // filename after line-rate must still be captured.
        let xml = #"<coverage line-rate="0.80"><class name="B" line-rate="0.50" filename="src/B.swift"></class></coverage>"#
        let r = CoverageReport.parseCobertura(xml)
        XCTAssertEqual(r?.percent, 80)
        XCTAssertEqual(r?.files.first?.path, "src/B.swift")
        XCTAssertEqual(r?.files.first?.rate, 0.5)
    }

    func testCoberturaOverallAnchoredToRootNotFirstClass() {
        // Root <coverage> carries the overall rate even though a class rate appears too.
        let xml = #"<coverage line-rate="0.40"><packages><package line-rate="0.90"><classes><class filename="a" line-rate="0.90"></class></classes></package></packages></coverage>"#
        XCTAssertEqual(CoverageReport.parseCobertura(xml)?.percent, 40)
    }

    func testFindNotPrunedWhenBaseDirNameIsPruneWord() throws {
        // A project whose own path contains ".build" must NOT prune its reports.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(".build").appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        try #"<coverage line-rate="0.77"></coverage>"#
            .write(to: base.appendingPathComponent("coverage.cobertura.xml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CoverageReport.find(in: base.path)?.percent, 77)
    }

    func testFindPicksReportInDir() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"<coverage line-rate="0.66"></coverage>"#
            .write(to: dir.appendingPathComponent("coverage.cobertura.xml"), atomically: true, encoding: .utf8)
        let r = CoverageReport.find(in: dir.path)
        XCTAssertEqual(r?.percent, 66)
    }

    func testFindPrunesNoiseDirsAndReturnsNilWhenAbsent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-\(UUID().uuidString)")
        let noise = dir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"<coverage line-rate="0.99"></coverage>"#
            .write(to: noise.appendingPathComponent("coverage.xml"), atomically: true, encoding: .utf8)
        XCTAssertNil(CoverageReport.find(in: dir.path))   // only report is under node_modules → pruned
    }
}
