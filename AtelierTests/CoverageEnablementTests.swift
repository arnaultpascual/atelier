// SPDX-License-Identifier: MIT
import XCTest
@testable import Atelier

final class CoverageEnablementTests: XCTestCase {

    private func tempProject(_ files: [String: String]) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cov-enable-\(UUID().uuidString)")
        for (rel, contents) in files {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }

    private func android() -> ProjectProfile { ProjectProfile.find(id: "android-kotlin")! }
    private func dotnet() -> ProjectProfile { ProjectProfile.find(id: "dotnet")! }

    func testAndroidWiredWhenJacocoPresent() throws {
        let p = try tempProject(["app/build.gradle.kts": "plugins { id(\"jacoco\") }\nandroid { }"])
        XCTAssertEqual(CoverageEnablement.status(profile: android(), projectPath: p), .wired)
    }

    func testAndroidMissingWhenNoJacoco() throws {
        let p = try tempProject(["app/build.gradle.kts": "plugins { id(\"com.android.application\") }\nandroid { }"])
        XCTAssertEqual(CoverageEnablement.status(profile: android(), projectPath: p), .missing(tool: "JaCoCo"))
    }

    func testDotnetWiredWhenCoverletPresent() throws {
        let p = try tempProject(["Sut.Tests/Sut.Tests.csproj": "<Project><ItemGroup><PackageReference Include=\"coverlet.collector\" /></ItemGroup></Project>"])
        XCTAssertEqual(CoverageEnablement.status(profile: dotnet(), projectPath: p), .wired)
    }

    func testDotnetMissingWhenNoCoverlet() throws {
        let p = try tempProject(["Sut.Tests/Sut.Tests.csproj": "<Project><ItemGroup><PackageReference Include=\"xunit\" /></ItemGroup></Project>"])
        XCTAssertEqual(CoverageEnablement.status(profile: dotnet(), projectPath: p), .missing(tool: "coverlet"))
    }

    func testGenericIsNotSupported() throws {
        let p = try tempProject(["README.md": "hi"])
        XCTAssertEqual(CoverageEnablement.status(profile: .generic, projectPath: p), .notSupported)
    }

    func testMarkerInsidePrunedBuildDirDoesNotCount() throws {
        // A generated build.gradle under build/ must not be mistaken for real wiring.
        let p = try tempProject([
            "app/build.gradle.kts": "plugins { id(\"com.android.application\") }",
            "app/build/generated/build.gradle": "jacoco { }",   // pruned
        ])
        XCTAssertEqual(CoverageEnablement.status(profile: android(), projectPath: p), .missing(tool: "JaCoCo"))
    }

    func testAndroidCommentMentionOfJacocoIsNotWired() throws {
        // A bare "jacoco" mention in a comment must not read as wired (needs plugin application).
        let p = try tempProject(["app/build.gradle.kts": "// TODO: add jacoco later\nplugins { id(\"com.android.application\") }"])
        XCTAssertEqual(CoverageEnablement.status(profile: android(), projectPath: p), .missing(tool: "JaCoCo"))
    }

    func testProjectUnderPrunedAncestorDirStillDetected() throws {
        // Project physically under a dir literally named "build" must not prune itself away.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("build").appendingPathComponent("proj-\(UUID().uuidString)")
        let f = base.appendingPathComponent("app/build.gradle.kts")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plugins { id(\"jacoco\") }".write(to: f, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        XCTAssertEqual(CoverageEnablement.status(profile: android(), projectPath: base.path), .wired)
    }

    func testDotnetWiredViaDirectoryBuildProps() throws {
        let p = try tempProject([
            "Directory.Build.props": "<Project><ItemGroup><PackageReference Include=\"coverlet.collector\" /></ItemGroup></Project>",
            "Sut.Tests/Sut.Tests.csproj": "<Project></Project>",
        ])
        XCTAssertEqual(CoverageEnablement.status(profile: dotnet(), projectPath: p), .wired)
    }

    func testSetupInstructionsPresentForSupportedModes() {
        XCTAssertNotNil(CoverageEnablement.setupInstructions(profile: android()))
        XCTAssertTrue(CoverageEnablement.setupInstructions(profile: android())!.contains("jacocoTestReport"))
        XCTAssertNil(CoverageEnablement.setupInstructions(profile: .generic))
    }
}
