// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class MCPCapabilityTests: XCTestCase {

    func testTaskWorkerGuidanceMentionsKeyToolsAndScopedSpec() {
        let g = MCPCapability.taskWorkerGuidance(featureId: "F42")
        XCTAssertTrue(g.contains("atelier://feature/F42/spec"))   // spec URI is feature-scoped
        XCTAssertTrue(g.contains("task_report_progress"))
        XCTAssertTrue(g.contains("spec_record_finding"))
        XCTAssertTrue(g.contains("coverage_get"))
        XCTAssertTrue(g.contains("task_signal_blocked"))
        XCTAssertTrue(g.contains("task_update_status"))
        XCTAssertTrue(g.lowercased().contains("do not silently deviate"))
    }

    func testManagedWorkerGuidanceIsCoverageFocused() {
        let g = MCPCapability.managedWorkerGuidance(featureId: "F1")
        XCTAssertTrue(g.contains("atelier://feature/F1/spec"))
        XCTAssertTrue(g.contains("coverage_get"))
        XCTAssertTrue(g.contains("coverage_uncovered"))
    }
}
