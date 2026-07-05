// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

/// Covers the pure decision + file-read helpers behind the MCP `resource_read`
/// op (the parts of AtelierBridgeListener that don't need a live socket/app).
final class AtelierBridgeResolutionTests: XCTestCase {

    func testResolutionFeatureMissingIsNotFound() {
        XCTAssertEqual(
            AtelierBridgeListener.briefResolution(featureFound: false, briefURL: nil),
            .notFound("feature not found"))
    }

    func testResolutionNoBriefRoomYetIsEmpty() {
        // Feature exists but brief stage not entered → empty living spec, not error.
        XCTAssertEqual(
            AtelierBridgeListener.briefResolution(featureFound: true, briefURL: nil),
            .empty)
    }

    func testResolutionWithURL() {
        let u = URL(fileURLWithPath: "/tmp/scratch/brief.md")
        XCTAssertEqual(
            AtelierBridgeListener.briefResolution(featureFound: true, briefURL: u),
            .url(u))
    }

    func testReadBriefFileMissingReturnsEmpty() {
        let u = URL(fileURLWithPath: "/tmp/atelier-absent-\(UUID().uuidString).md")
        XCTAssertEqual(AtelierBridgeListener.readBriefFile(u), "")   // tolerate not-yet-created
    }

    func testReadBriefFileReturnsContents() throws {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atelier-brief-\(UUID().uuidString).md")
        try "# Living spec\n\nbody\n".write(to: u, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertEqual(AtelierBridgeListener.readBriefFile(u), "# Living spec\n\nbody\n")
    }

    func testMarkdownResourceShape() {
        let v = AtelierBridgeListener.markdownResource("hi")
        XCTAssertEqual(v["text"]?.stringValue, "hi")
        XCTAssertEqual(v["mimeType"]?.stringValue, "text/markdown")
    }
}
