// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class FeatureAttachmentsTests: XCTestCase {

    private func tempRoot() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("featatt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }
    private func makeFile(_ dir: String, _ name: String, _ contents: String = "x") throws -> URL {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testStoreListRemoveRoundTrip() throws {
        let root = try tempRoot()
        let src = try makeFile(root, "mockup.png", "img-bytes")
        let stored = try FeatureAttachments.store(sourceURL: src, featureId: "F1", projectRoot: root)
        XCTAssertTrue(stored.path.contains(".atelier/attachments/feature-F1/"))
        XCTAssertEqual(FeatureAttachments.list(projectRoot: root, featureId: "F1"), [stored])
        XCTAssertTrue(FeatureAttachments.list(projectRoot: root, featureId: "F2").isEmpty)   // scoped
        FeatureAttachments.remove(fileURL: stored)
        XCTAssertTrue(FeatureAttachments.list(projectRoot: root, featureId: "F1").isEmpty)
    }

    func testStoreReplacesByName() throws {
        // A persistent, user-curated store must REPLACE a re-shared file, not accumulate
        // stale collision-suffixed copies the decomposer could route (mockup.png + mockup-2.png).
        let root = try tempRoot()
        _ = try FeatureAttachments.store(sourceURL: try makeFile(root, "spec.pdf", "v1"),
                                         featureId: "F1", projectRoot: root)
        // Simulate a corrected re-share with the same name (source lives elsewhere).
        let updatedDir = URL(fileURLWithPath: root).appendingPathComponent("v2")
        try FileManager.default.createDirectory(at: updatedDir, withIntermediateDirectories: true)
        let updated = updatedDir.appendingPathComponent("spec.pdf")
        try "v2".write(to: updated, atomically: true, encoding: .utf8)
        let stored = try FeatureAttachments.store(sourceURL: updated, featureId: "F1", projectRoot: root)

        let files = FeatureAttachments.list(projectRoot: root, featureId: "F1")
        XCTAssertEqual(files.count, 1)                                   // no stale sibling
        XCTAssertEqual(stored.lastPathComponent, "spec.pdf")             // plain name, no -2 suffix
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "v2")   // latest content wins
    }

    func testDuplicateBasenamesDetection() {
        let files = [URL(fileURLWithPath: "/a/logo.png"), URL(fileURLWithPath: "/b/Logo.PNG"),
                     URL(fileURLWithPath: "/c/spec.pdf")]
        XCTAssertEqual(FeatureAttachments.duplicateBasenames(in: files), ["logo.png"])
        XCTAssertTrue(FeatureAttachments.duplicateBasenames(in: [files[0], files[2]]).isEmpty)
    }

    func testRemoveAllDeletesTheStore() throws {
        let root = try tempRoot()
        _ = try FeatureAttachments.store(sourceURL: try makeFile(root, "mockup.png"),
                                         featureId: "F1", projectRoot: root)
        FeatureAttachments.removeAll(projectRoot: root, featureId: "F1")
        XCTAssertTrue(FeatureAttachments.list(projectRoot: root, featureId: "F1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: FeatureAttachments.directory(projectRoot: root, featureId: "F1").path))
    }

    func testResourceKindExactRouting() {
        typealias K = AtelierBridgeListener.ResourceKind
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/F1/spec", featureId: "F1"), K.spec)
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/F1/brief", featureId: "F1"), K.brief)
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/F1/attachments", featureId: "F1"), K.attachments)
        // Wrong feature id, per-file sub-uri, typo → unknown (must fail, never fall through).
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/OTHER/attachments", featureId: "F1"), K.unknown)
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/F1/attachments/mockup.png", featureId: "F1"), K.unknown)
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "atelier://feature/F1/specc", featureId: "F1"), K.unknown)
        XCTAssertEqual(AtelierBridgeListener.resourceKind(uri: "", featureId: "F1"), K.unknown)
    }

    func testMatchByFilenameCaseInsensitiveAndPathTolerant() throws {
        let root = try tempRoot()
        let a = try FeatureAttachments.store(sourceURL: try makeFile(root, "Mockup.PNG"), featureId: "F1", projectRoot: root)
        let b = try FeatureAttachments.store(sourceURL: try makeFile(root, "api-spec.pdf"), featureId: "F1", projectRoot: root)
        let files = FeatureAttachments.list(projectRoot: root, featureId: "F1")
        // Case-insensitive, tolerates a stray path prefix, dedups, ignores unknowns.
        let matched = FeatureAttachments.match(names: ["mockup.png", "some/dir/API-SPEC.PDF", "mockup.png", "ghost.txt"], in: files)
        XCTAssertEqual(Set(matched), Set([a, b]))
        XCTAssertEqual(matched.count, 2)
    }

    func testDraftParsingCarriesAttachments() throws {
        let json = """
        {"tasks":[
          {"id":"t1","title":"Build the posts screen","description":"## Goal\\nUI","priority":"high",
           "labels":["ui"],"depends_on":[],"attachments":["Mockup.PNG"," ", "spec.pdf"],"suggested_model":""},
          {"id":"t2","title":"Repository layer","description":"x","priority":"medium",
           "labels":[],"depends_on":["t1"],"suggested_model":"claude-sonnet-4-6"}
        ]}
        """
        let drafts = try AIAssistant.parseTaskDrafts(json)
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].attachments, ["Mockup.PNG", "spec.pdf"])   // trimmed, blanks dropped
        XCTAssertEqual(drafts[1].attachments, [])                            // field absent → []
    }

    func testAttachmentsListingFormat() {
        XCTAssertTrue(AtelierBridgeListener.attachmentsListing(files: []).contains("No shared files"))
        let listing = AtelierBridgeListener.attachmentsListing(
            files: [URL(fileURLWithPath: "/p/.atelier/attachments/feature-F1/mockup.png")])
        XCTAssertTrue(listing.contains("mockup.png"))
        XCTAssertTrue(listing.contains("/p/.atelier/attachments/feature-F1/mockup.png"))
        XCTAssertTrue(listing.contains("Read"))
    }
}
