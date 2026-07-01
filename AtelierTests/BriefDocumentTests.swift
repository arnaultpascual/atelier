// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class BriefDocumentTests: XCTestCase {

    func testParseRenderRoundTripIsStable() {
        let md = "# My Feature\n\n## Overview\n\nDo the thing.\n\n## Requirements\n\n- must be fast\n"
        let doc = BriefDocument.parse(md)
        let again = BriefDocument.parse(doc.rendered())
        XCTAssertEqual(doc, again)
        XCTAssertTrue(doc.rendered().contains("# My Feature"))
        XCTAssertTrue(doc.rendered().contains("## Overview"))
    }

    func testSetOverviewCreatesAndReplaces() {
        var doc = BriefDocument.parse("")
        doc.setOverview("First.")
        XCTAssertTrue(doc.rendered().contains("## Overview\n\nFirst."))
        doc.setOverview("Second.")
        let r = doc.rendered()
        XCTAssertTrue(r.contains("Second."))
        XCTAssertFalse(r.contains("First."))
    }

    func testAddRequirementWithAndWithoutPriority() {
        var doc = BriefDocument.parse("")
        doc.addRequirement("plain requirement")
        doc.addRequirement("urgent one", priority: "high")
        let r = doc.rendered()
        XCTAssertTrue(r.contains("## Requirements"))
        XCTAssertTrue(r.contains("- plain requirement"))
        XCTAssertTrue(r.contains("- [HIGH] urgent one"))
    }

    func testAcceptanceCriteriaAreCheckboxes() {
        var doc = BriefDocument.parse("")
        doc.addAcceptanceCriterion("returns 200")
        XCTAssertTrue(doc.rendered().contains("## Acceptance Criteria"))
        XCTAssertTrue(doc.rendered().contains("- [ ] returns 200"))
    }

    func testOpenQuestionAddAndResolve() {
        var doc = BriefDocument.parse("")
        doc.addOpenQuestion("which db?")
        doc.addOpenQuestion("which auth?")
        XCTAssertTrue(doc.resolveOpenQuestion(index: 2, answer: "OAuth"))
        let r = doc.rendered()
        XCTAssertTrue(r.contains("- [ ] which db?"))          // first still open
        XCTAssertTrue(r.contains("- [x] which auth? — **A:** OAuth"))
    }

    func testResolveMissingOpenQuestionReturnsFalse() {
        var doc = BriefDocument.parse("")
        doc.addOpenQuestion("only one")
        XCTAssertFalse(doc.resolveOpenQuestion(index: 5, answer: "n/a"))
    }

    func testRecordDecisionAndReference() {
        var doc = BriefDocument.parse("")
        doc.recordDecision("use SQLite", rationale: "simple + embedded")
        doc.attachReference("https://example.com/spec", note: "upstream")
        doc.attachReference("/local/path")
        let r = doc.rendered()
        XCTAssertTrue(r.contains("- **use SQLite** — simple + embedded"))
        XCTAssertTrue(r.contains("- https://example.com/spec — upstream"))
        XCTAssertTrue(r.contains("- /local/path"))
    }

    func testRecordFindingWithImpactAndWorkaround() {
        var doc = BriefDocument.parse("")
        doc.recordFinding("Stripe API lacks X", impact: "cannot do Y directly", workaround: "poll Z instead")
        let r = doc.rendered()
        XCTAssertTrue(r.contains("## Build Findings"))
        XCTAssertTrue(r.contains("**Stripe API lacks X**"))
        XCTAssertTrue(r.contains("Impact: cannot do Y directly"))
        XCTAssertTrue(r.contains("Workaround: poll Z instead"))
    }

    func testSectionsLandInCanonicalOrderRegardlessOfInsertionOrder() {
        var doc = BriefDocument.parse("")
        doc.recordFinding("late finding")           // Build Findings (last)
        doc.setOverview("overview")                 // Overview (first)
        doc.addRequirement("req")                   // Requirements (second)
        let headings = doc.sections.map { $0.heading }
        XCTAssertEqual(headings, ["Overview", "Requirements", "Build Findings"])
    }

    func testFreeformAppendSectionGoesToEnd() {
        var doc = BriefDocument.parse("")
        doc.setOverview("o")
        doc.appendSection(heading: "Notes", markdown: "some notes")
        XCTAssertEqual(doc.sections.last?.heading, "Notes")
        XCTAssertTrue(doc.rendered().contains("## Notes\n\nsome notes"))
    }

    func testAppendsToExistingSectionMerges() {
        var doc = BriefDocument.parse("## Requirements\n\n- one\n")
        doc.addRequirement("two")
        let body = doc.sections.first { $0.heading == "Requirements" }?.body
        XCTAssertEqual(body, "- one\n- two")
    }

    func testPreamblePreservedWhenMutating() {
        var doc = BriefDocument.parse("# Title\n\nintro paragraph\n\n## Overview\n\nx")
        doc.addRequirement("r")
        XCTAssertTrue(doc.rendered().hasPrefix("# Title"))
        XCTAssertTrue(doc.rendered().contains("intro paragraph"))
    }
}
