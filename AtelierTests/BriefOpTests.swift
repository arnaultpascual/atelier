// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

/// Covers the pure brief-op dispatcher behind the MCP `brief_*` / `spec_record_finding`
/// bridge ops (the part that doesn't need a socket or app).
final class BriefOpTests: XCTestCase {

    func testEachBriefOpMutatesAndAcks() {
        var doc = BriefDocument.parse("")
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("brief_set_overview",
            args: .object(["markdown": .string("Build a widget.")]), to: &doc), "Overview updated.")
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("brief_add_requirement",
            args: .object(["text": .string("be fast"), "priority": .string("high")]), to: &doc), "Requirement added.")
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("brief_add_acceptance_criterion",
            args: .object(["text": .string("returns 200")]), to: &doc), "Acceptance criterion added.")
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("brief_record_decision",
            args: .object(["decision": .string("use SQLite"), "rationale": .string("simple")]), to: &doc), "Decision recorded.")
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("spec_record_finding",
            args: .object(["finding": .string("API lacks X"), "workaround": .string("poll")]), to: &doc),
            "Finding recorded in the spec.")
        let r = doc.rendered()
        XCTAssertTrue(r.contains("Build a widget."))
        XCTAssertTrue(r.contains("- [HIGH] be fast"))
        XCTAssertTrue(r.contains("- [ ] returns 200"))
        XCTAssertTrue(r.contains("**use SQLite** — simple"))
        XCTAssertTrue(r.contains("## Build Findings"))
        XCTAssertTrue(r.contains("Workaround: poll"))
    }

    func testBadArgsAndUnknownOpReturnNil() {
        var doc = BriefDocument.parse("")
        XCTAssertNil(AtelierBridgeListener.applyBriefOp("brief_add_requirement", args: .object([:]), to: &doc))
        XCTAssertNil(AtelierBridgeListener.applyBriefOp("nope", args: .object([:]), to: &doc))
        XCTAssertNil(AtelierBridgeListener.applyBriefOp("brief_append_section",
            args: .object(["heading": .string("H")]), to: &doc))   // missing markdown
    }

    func testResolveOpenQuestion() {
        var doc = BriefDocument.parse("")
        _ = AtelierBridgeListener.applyBriefOp("brief_add_open_question", args: .object(["text": .string("which db?")]), to: &doc)
        XCTAssertNil(AtelierBridgeListener.applyBriefOp("brief_resolve_open_question",
            args: .object(["index": .int(9), "answer": .string("x")]), to: &doc))   // no such question
        XCTAssertEqual(AtelierBridgeListener.applyBriefOp("brief_resolve_open_question",
            args: .object(["index": .int(1), "answer": .string("SQLite")]), to: &doc), "Open question 1 resolved.")
        XCTAssertTrue(doc.rendered().contains("**A:** SQLite"))
    }
}
