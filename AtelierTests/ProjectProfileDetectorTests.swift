// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class ProjectProfileDetectorTests: XCTestCase {

    private func tempProject(_ files: [String: String]) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("detect-\(UUID().uuidString)")
        for (rel, contents) in files {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }
    private func detectID(_ files: [String: String]) throws -> String {
        ProjectProfileDetector.detect(at: try tempProject(files)).profile.id
    }

    // MARK: Python family precedence (django → fastapi → python)

    func testDjangoViaManagePy() throws {
        XCTAssertEqual(try detectID(["manage.py": "import django", "requirements.txt": "Django==5.0\n"]), "django")
    }

    func testDjangoViaDependencyOnly() throws {
        XCTAssertEqual(try detectID(["pyproject.toml": "[project]\ndependencies = [\"django>=5\"]\n"]), "django")
    }

    func testFastAPIViaDependency() throws {
        XCTAssertEqual(try detectID(["requirements.txt": "fastapi==0.115\nuvicorn\n", "app.py": "from fastapi import FastAPI"]), "fastapi")
    }

    func testPlainPythonFallback() throws {
        XCTAssertEqual(try detectID(["pyproject.toml": "[project]\ndependencies = [\"requests\"]\n"]), "python")
    }

    func testDjangoWinsOverFastAPIWhenBoth() throws {
        // manage.py present + fastapi also listed → django (checked first).
        XCTAssertEqual(try detectID(["manage.py": "x", "requirements.txt": "django\nfastapi\n"]), "django")
    }

    // MARK: JS/TS fork (next → react-vite → other frontend → node)

    private func pkg(_ deps: String) -> [String: String] { ["package.json": "{\"dependencies\": {\(deps)}}"] }

    func testNextWinsOverReactVite() throws {
        // Next projects also have react + sometimes vite; next must win.
        XCTAssertEqual(try detectID(pkg("\"next\":\"14\",\"react\":\"18\",\"vite\":\"5\"")), "web-nextjs")
    }
    func testReactViteDetected() throws {
        XCTAssertEqual(try detectID(pkg("\"react\":\"18\",\"react-dom\":\"18\",\"vite\":\"5\"")), "react-vite")
    }
    func testReactWithoutViteFallsToWebNext() throws {
        // CRA/webpack React (no vite) → the general frontend mode, not react-vite.
        XCTAssertEqual(try detectID(pkg("\"react\":\"18\",\"react-dom\":\"18\"")), "web-nextjs")
    }
    func testNodeBackendWhenNoFrontend() throws {
        XCTAssertEqual(try detectID(pkg("\"express\":\"4\"")), "node-backend")
    }
    func testViteWithoutReactIsNodeBackend() throws {
        // A vite tool project without react shouldn't be react-vite.
        XCTAssertEqual(try detectID(pkg("\"vite\":\"5\"")), "node-backend")
    }
    func testJsModesHaveNpmTestGateAndCoverageSetup() {
        for id in ["web-nextjs", "react-vite", "node-backend"] {
            let p = ProjectProfile.find(id: id)!
            XCTAssertEqual(p.build.fastTestCommands.first?.command, "npm test", "\(id) gate")
            XCTAssertNotNil(p.build.coverageSetup, "\(id) coverageSetup")
        }
    }

    func testPythonFamilyHasPytestGateAndCoverage() {
        for id in ["django", "fastapi", "python"] {
            let p = ProjectProfile.find(id: id)!
            XCTAssertEqual(p.build.fastTestCommands.first?.command, "pytest", "\(id) gate")
            XCTAssertEqual(p.build.coverageTarget, 90, "\(id) soft target")
            XCTAssertNotNil(p.build.coverageSetup, "\(id) coverageSetup")
        }
    }
}
