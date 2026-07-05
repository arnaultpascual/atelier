// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class RecetteBuilderTests: XCTestCase {

    private func brief(_ md: String) -> BriefDocument { BriefDocument.parse(md) }

    func testSeedsAlwaysHaveSmokeFirstAndRegressionLast() {
        let items = RecetteBuilder.deterministicSeeds(brief: nil, taskTitles: [], coverage: nil,
                                                      coverageTarget: nil, featureName: "X")
        XCTAssertEqual(items.first?.id, "smoke")
        XCTAssertEqual(items.first?.priority, .p0)
        XCTAssertEqual(items.last?.id, "reg")
        XCTAssertEqual(items.last?.priority, .p1)
    }

    func testAcceptanceCriteriaBecomeP0Items() {
        let doc = brief("""
        ## Acceptance Criteria

        - [ ] The /health endpoint returns 200
        - [x] Errors are logged

        ## Build Findings

        - **Rate limiter unavailable** · Workaround: in-memory bucket
        """)
        let items = RecetteBuilder.deterministicSeeds(brief: doc, taskTitles: ["Add route", "Wire logger"],
                                                      coverage: nil, coverageTarget: nil, featureName: "Health")
        let ac = items.filter { $0.group == "Critères d'acceptation" }
        XCTAssertEqual(ac.count, 2)
        XCTAssertTrue(ac.allSatisfy { $0.priority == .p0 })
        XCTAssertEqual(ac.first?.expected, "The /health endpoint returns 200")   // full criterion is the pass condition

        let findings = items.filter { $0.group == "Contraintes & contournements" }
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.priority, .p1)
        XCTAssertFalse(findings.first?.title.contains("**") ?? true)   // markdown bold stripped

        let tasks = items.filter { $0.group == "Tâches livrées" }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy { $0.priority == .p2 })
    }

    func testNoCoverageMeansNoCoverageItem() {
        let items = RecetteBuilder.deterministicSeeds(brief: nil, taskTitles: [], coverage: nil,
                                                      coverageTarget: nil, featureName: "X")
        XCTAssertNil(items.first { $0.group == "Couverture" })
    }

    func testRenderEscapesAndCarriesPriorityData() {
        let doc = brief("## Acceptance Criteria\n\n- [ ] Handles <script> & \"quotes\" safely\n")
        let items = RecetteBuilder.deterministicSeeds(brief: doc, taskTitles: [], coverage: nil,
                                                      coverageTarget: nil, featureName: "Sec & <b>")
        let html = RecetteBuilder.renderHTML(featureName: "Sec & <b>", projectName: "Proj",
                                             items: items, generatedNote: "généré")
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("data-prio=\"P0\""))
        XCTAssertTrue(html.contains("&lt;script&gt;"))          // criterion text escaped
        XCTAssertTrue(html.contains("Sec &amp; &lt;b&gt;"))     // feature name escaped in title/header
        XCTAssertFalse(html.contains("<script>alert"))          // no raw injection
        XCTAssertTrue(html.contains("localStorage"))            // interactive script present
    }

    func testRecetteURLShape() {
        let url = RecetteBuilder.recetteURL(projectPath: "/tmp/proj", featureName: "My Feature!")
        XCTAssertEqual(url.lastPathComponent, "FEATURE-my-feature-recette.html")
        XCTAssertTrue(url.path.hasPrefix("/tmp/proj/"))
    }

    func testParseRecetteItemsTolerant() throws {
        let json = """
        Voici le plan :
        {"items":[
          {"id":"ac1","group":"Critères d'acceptation","title":"200 sur /health","priority":"p0","validates":"AC","steps":["curl /health"],"expected":"200","hint":null},
          {"title":"Sans id ni steps","priority":"weird"},
          {"title":"   ","priority":"p2"}
        ]}
        """
        let items = try AIAssistant.parseRecetteItems(json)
        XCTAssertEqual(items.count, 2)                       // blank-title dropped
        XCTAssertEqual(items[0].priority, .p0)
        XCTAssertEqual(items[0].steps, ["curl /health"])
        XCTAssertEqual(items[1].id, "ri2")                  // id backfilled by index
        XCTAssertEqual(items[1].priority, .p1)              // bad priority → p1
        XCTAssertEqual(items[1].group, "À vérifier")        // missing group default
        XCTAssertEqual(items[1].steps, ["À vérifier."])     // empty steps default
    }

    func testBulletsStripMarkers() {
        let doc = brief("""
        ## Requirements

        - [HIGH] Must paginate
        - Plain requirement

        ## Acceptance Criteria

        - [ ] Unchecked crit
        - [x] Checked crit
        """)
        XCTAssertEqual(doc.bullets(in: "Requirements"), ["Must paginate", "Plain requirement"])
        XCTAssertEqual(doc.bullets(in: "Acceptance Criteria"), ["Unchecked crit", "Checked crit"])
        XCTAssertEqual(doc.bullets(in: "Nonexistent"), [])
    }
}
