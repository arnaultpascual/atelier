// SPDX-License-Identifier: MIT
import Foundation

/// Builds a two-part `TestDossier` for a finished feature. Part A (automated coverage) is
/// assembled here in Swift from real run results + git diff — never from the model. Part B
/// (manual QA) is one `AIAssistant.generateDossierContent` pass. Callable from both the autopilot
/// (`markMerged`) and the manual flow (`ReviewSection`).
enum DossierBuilder {

    /// `testResult` MUST come from the same tree the dossier describes (the worktree pre-merge),
    /// so Part A's "tests" line and Part B's diff reading agree.
    static func build(task: AtelierTask,
                      profile: ProjectProfile,
                      project: Project,
                      branch: String,
                      worktreePath: String,
                      testResult: TestRunner.Result,
                      buildOutcome: TestRunner.CommandOutcome?,
                      review: ReviewReport?,
                      alignment: AIAssistant.AlignmentVerdict?,
                      apiKey: String?) async -> TestDossier {
        let acceptance = parseAcceptanceCriteria(task.descriptionMd ?? "")
        let changed = (try? await GitService.changedFiles(projectPath: project.path,
                                                          branch: branch, taskId: task.id)) ?? []
        let changedPaths = changed.map(\.path)
        let regexes = profile.build.testDiscoveryGlobs.map { TestIntegrityChecker.globToRegex($0) }
        let testFiles = changedPaths.filter { p in regexes.contains { p.range(of: $0, options: .regularExpression) != nil } }
        let perCommand = testResult.perCommand.map { (command: $0.command, passed: $0.passed) }
        let deviceCommands = profile.build.testCommands
            .filter { $0.tier == .optional || $0.requiresDevice }
            .map(\.command)
        let buildStatus: String = {
            if let o = buildOutcome { return "\(o.command) → \(o.passed ? "PASS" : "FAIL")" }
            guard profile.build.buildCommand != nil || project.verifyBuildCommand != nil else { return "no build step" }
            return "not run (app build is opt-in)"
        }()

        // Coverage (informational, never a gate): if the mode declares a coverage command and the
        // gate is green, re-run tests once with coverage collection and read the Cobertura line-rate.
        let coverage = await measureCoverage(profile: profile, project: project,
                                             worktreePath: worktreePath,
                                             gateGreen: testResult.passed && testResult.ranAnything)

        // Part B (LLM). Best-effort: a failure still yields a useful Part A.
        let content = try? await AIAssistant.generateDossierContent(
            taskTitle: task.title,
            brief: task.descriptionMd ?? "",
            acceptanceCriteria: acceptance,
            changedFiles: changedPaths,
            testFiles: testFiles,
            testResultSummary: testResult.ranAnything ? testResult.summaryLine : "no automated tests for this mode",
            perCommand: perCommand,
            buildStatus: buildStatus,
            coverage: coverage,
            modeHint: profile.build.testScaffoldingHint,
            reviewSummary: review?.summary,
            reviewFindings: (review?.findings ?? []).map(\.oneLine),
            deviceCommands: deviceCommands,
            worktreePath: worktreePath,
            apiKey: apiKey)

        let md = render(task: task, profile: profile, changed: changed, testFiles: testFiles,
                        testResult: testResult, buildStatus: buildStatus, coverage: coverage,
                        alignment: alignment, content: content)
        return TestDossier(taskId: task.id, taskTitle: task.title, costUsd: content?.costUsd ?? 0, markdown: md)
    }

    /// Pulls the bullet/line items under a "## Acceptance criteria" heading from a task body.
    static func parseAcceptanceCriteria(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        var out: [String] = []
        var inSection = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("## ") {
                inSection = t.lowercased().contains("acceptance")
                continue
            }
            guard inSection else { continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                out.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if let dot = t.first, dot.isNumber, t.contains(".") {
                // "1. foo"
                if let range = t.range(of: ". ") { out.append(String(t[range.upperBound...])) }
            }
        }
        return out
    }

    // MARK: - Rendering (Part A deterministic, Part B from `content`)

    private static func render(task: AtelierTask,
                               profile: ProjectProfile,
                               changed: [GitService.ChangedFile],
                               testFiles: [String],
                               testResult: TestRunner.Result,
                               buildStatus: String,
                               coverage: String?,
                               alignment: AIAssistant.AlignmentVerdict?,
                               content: AIAssistant.DossierContent?) -> String {
        var md = "# Cahier de recette — \(task.title)\n\n"
        md += "_Task `\(task.id)` · generated \(Date().formatted(date: .abbreviated, time: .shortened))_\n\n"

        // ---- Part A: guaranteed by code & tests ----
        md += "## Part A — Guaranteed by code & tests (no manual check needed)\n\n"
        md += "### Build & gate\n"
        md += "- Build: \(buildStatus)\n"
        if let coverage { md += "- Coverage: \(coverage) — informational, not a gate\n" }
        if testResult.ranAnything {
            for c in testResult.perCommand {
                md += "- Tests: \(c.passed ? "✅" : "❌") `\(c.command)` (\(Int(c.duration))s)\n"
            }
            md += "- Summary: \(testResult.summaryLine)\n"
        } else {
            md += "- Tests: _no automated test command for this mode (gate is informational)._\n"
        }
        // Test-change alignment: prefer the live verdict, else fall back to the task's persisted state.
        if let a = alignment {
            md += "- Test changes: \(a.aligned ? "aligned" : "needs rework") — \(a.rationale)\n"
        } else {
            switch task.testIntegrity {
            case .evolved: md += "- Test changes: evolved with the design\(task.testChangeNote.map { " — \($0)" } ?? "")\n"
            case .suspect: md += "- Test changes: flagged for review\(task.testChangeNote.map { " — \($0)" } ?? "")\n"
            case .intact, .unevaluated: break
            }
        }
        md += "\n"

        if !testFiles.isEmpty {
            md += "### Tests added/changed\n"
            for f in testFiles {
                let asserts = content?.testFileAsserts[f]
                md += "- `\(f)`\(asserts.map { " — \($0)" } ?? "")\n"
            }
            md += "\n"
        }

        if let criteria = content?.criteria, !criteria.isEmpty {
            md += "### Acceptance criteria\n"
            for c in criteria {
                let mark: String
                switch c.coverage.lowercased() {
                case "automated": mark = "✅ automated"
                case "partial":   mark = "🟡 partial"
                default:           mark = "👤 manual"
                }
                md += "- \(mark) — \(c.text)\(c.evidence.isEmpty ? "" : " → \(c.evidence)")\n"
            }
            md += "\n"
        }

        if !changed.isEmpty {
            md += "### Changed files\n"
            for f in changed.prefix(60) {
                md += "- `\(f.path)` (\(f.status.label))\n"
            }
            md += "\n"
        }

        // ---- Part B: functional recette ----
        md += "## Part B — Functional recette (verify by hand in the running app)\n\n"
        let checks = content?.manualChecks ?? []
        if checks.isEmpty {
            md += "_No functional checks identified — the behavior appears fully guaranteed by code & tests. "
            md += "Still smoke-test the happy path before shipping._\n"
        } else {
            var idx = 0
            for c in checks {
                idx += 1
                md += "- [ ] **[\(c.category)] B-\(idx) — \(c.title)**\n"
                if !c.howTo.isEmpty { md += "      How: \(c.howTo)\n" }
                if !c.why.isEmpty { md += "      Why: \(c.why)\n" }
            }
        }
        return md
    }

    // MARK: - Coverage (informational)

    /// Best-effort, INFORMATIONAL coverage for the recette. Re-runs the mode's coverage command once
    /// (e.g. `dotnet test --collect:"XPlat Code Coverage"`, which writes Cobertura under TestResults/)
    /// and reads the line-rate. Never a gate: any failure → nil. Only runs when the gate is green and
    /// the mode declares a coverage command — so it never slows down a red/no-test feature.
    /// Internal (not private) so the feature-level synthesis can reuse it on the integration branch.
    static func measureCoverage(profile: ProjectProfile, project: Project,
                                worktreePath: String, gateGreen: Bool) async -> String? {
        guard gateGreen, let cmd = profile.build.coverageCommand else { return nil }
        guard let outcome = await TestRunner.runCommand(cmd, worktreePath: worktreePath,
                                                        profile: profile, mainRepoPath: project.path,
                                                        timeoutSeconds: 900),
              outcome.passed else { return nil }
        // Multi-format: Cobertura (dotnet/python/go), LCOV (rust/swift/node), JaCoCo (android/JVM),
        // json-summary (node) — whichever the mode's coverage command emitted into the worktree.
        guard let report = CoverageReport.find(in: worktreePath) else { return nil }
        return "lines \(report.percent)%"
    }

    /// Numeric line-rate (0…1) from the newest coverage report already written under `worktreePath`
    /// — reads a report a prior `measureCoverage` produced; does NOT run tests. nil = no/unreadable
    /// report. Used by the soft coverage-improvement round to decide "below target?". Multi-format
    /// via CoverageReport (Cobertura / LCOV / JaCoCo / json-summary).
    static func coverageLineRate(worktreePath: String) -> Double? {
        CoverageReport.find(in: worktreePath)?.lineRate
    }
}
