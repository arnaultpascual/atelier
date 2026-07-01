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

    func testMalformedReturnsNil() {
        XCTAssertNil(CoverageReport.parseCobertura("<coverage>no rate</coverage>"))
        XCTAssertNil(CoverageReport.parseLcov("garbage"))
        XCTAssertNil(CoverageReport.parseJsonSummary("{}"))
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
