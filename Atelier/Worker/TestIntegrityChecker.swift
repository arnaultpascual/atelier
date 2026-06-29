// SPDX-License-Identifier: MIT
import Foundation

/// Deterministic, LLM-free inspection of how the test SUITE changed in a worktree vs its base.
///
/// It produces *signals*, it never judges: a deleted assertion looks identical whether the worker
/// legitimately redesigned or weakened-to-pass. The signals decide (a) whether the worker owed a
/// `## TEST-CHANGES` declaration (any test file touched) and (b) whether to spend an LLM call to
/// adjudicate (`looksWeakened`). The expensive judgment only runs when this cheap pass flags it.
enum TestIntegrityChecker {
    struct Signals: Sendable {
        let testFilesTouched: [String]
        let deletedTestFiles: [String]
        let addedSkips: Int            // new @Ignore/@Disabled/skip/xit/#[ignore] lines
        let removedAssertions: Int     // removed assert-ish lines
        let noOpedAssertions: Int      // added assertTrue(true) / assertEquals(x, x) style
        let netTestCaseDelta: Int      // added test-case decls − removed
        let diffText: String           // the test-file diff (fed to the LLM adjudicator)

        /// Any test file changed at all → the worker owed a `## TEST-CHANGES` declaration.
        var anyTestChange: Bool { !testFilesTouched.isEmpty }
        /// The suite shrank/softened → spend an LLM call to decide legitimate-vs-weakening.
        var looksWeakened: Bool {
            !deletedTestFiles.isEmpty || addedSkips > 0 || removedAssertions > 0
                || noOpedAssertions > 0 || netTestCaseDelta < 0
        }
        var summaryLine: String {
            guard anyTestChange else { return "No test files changed." }
            var parts: [String] = []
            if netTestCaseDelta != 0 { parts.append("\(netTestCaseDelta > 0 ? "+" : "")\(netTestCaseDelta) tests") }
            if !deletedTestFiles.isEmpty { parts.append("\(deletedTestFiles.count) test file(s) deleted") }
            if addedSkips > 0 { parts.append("+\(addedSkips) skip/ignore") }
            if removedAssertions > 0 { parts.append("−\(removedAssertions) assertions") }
            if noOpedAssertions > 0 { parts.append("\(noOpedAssertions) no-op assertion(s)") }
            if parts.isEmpty { parts.append("\(testFilesTouched.count) test file(s) modified") }
            return parts.joined(separator: ", ")
        }

        static let none = Signals(testFilesTouched: [], deletedTestFiles: [], addedSkips: 0,
                                  removedAssertions: 0, noOpedAssertions: 0, netTestCaseDelta: 0, diffText: "")
    }

    /// Inspects the test-file delta on `branch` vs its merge-base with HEAD. Returns `.none` when
    /// the mode declares no test globs (→ caller maps to `.unevaluated`) or nothing changed.
    static func inspect(profile: ProjectProfile,
                        projectPath: String,
                        branch: String,
                        taskId: String) async -> Signals {
        let globs = profile.build.testDiscoveryGlobs
        guard !globs.isEmpty else { return .none }

        let changed = (try? await GitService.changedFiles(projectPath: projectPath,
                                                          branch: branch, taskId: taskId)) ?? []
        let regexes = globs.map { globToRegex($0) }
        let testChanged = changed.filter { f in regexes.contains { matches(f.path, $0) } }
        guard !testChanged.isEmpty else {
            return Signals(testFilesTouched: [], deletedTestFiles: [], addedSkips: 0,
                           removedAssertions: 0, noOpedAssertions: 0, netTestCaseDelta: 0, diffText: "")
        }

        let deleted = testChanged.filter { $0.status == .deleted }.map(\.path)
        let worktreePath = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier-worktrees").appendingPathComponent(taskId).path
        let base = await GitService.mergeBaseRef(projectPath: projectPath, branch: branch)
        // Intent-to-add brand-new test files so their content shows in the diff (the LLM/heuristics
        // otherwise run blind on additions).
        let untracked = testChanged.filter { $0.status == .untracked }.map(\.path)
        await GitService.intentToAdd(worktreePath: worktreePath, paths: untracked)
        let diff = await GitService.worktreeDiff(worktreePath: worktreePath, ref: base,
                                                 paths: testChanged.map(\.path))

        let (added, removed) = splitDiffLines(diff)
        let addedSkips = added.filter(looksLikeSkip).count
        let removedAsserts = removed.filter(looksLikeAssertion).count
        let noOps = added.filter(looksLikeNoOpAssertion).count
        let caseDelta = added.filter(looksLikeTestCase).count - removed.filter(looksLikeTestCase).count

        return Signals(testFilesTouched: testChanged.map(\.path),
                       deletedTestFiles: deleted,
                       addedSkips: addedSkips,
                       removedAssertions: removedAsserts,
                       noOpedAssertions: noOps,
                       netTestCaseDelta: caseDelta,
                       diffText: String(diff.prefix(16_000)))   // cap for the LLM call
    }

    /// The worker's declared test-change rationale. The worker runs with cwd = the worktree and is
    /// told to write `.atelier/test-changes/<id>.md`, so it lands INSIDE the worktree — read it there
    /// (not the main project root, which is a separate checkout and wouldn't have it pre-merge).
    static func declaredNote(worktreePath: String, taskId: String) -> String? {
        let url = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".atelier/test-changes/\(taskId).md")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - Heuristics (intentionally language-agnostic; false positives only cost an LLM call)

    private static func splitDiffLines(_ diff: String) -> (added: [String], removed: [String]) {
        var added: [String] = []
        var removed: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("+++") || s.hasPrefix("---") { continue }   // file headers
            if s.hasPrefix("+") { added.append(String(s.dropFirst())) }
            else if s.hasPrefix("-") { removed.append(String(s.dropFirst())) }
        }
        return (added, removed)
    }

    private static func looksLikeAssertion(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("assert") || l.contains("xctassert") || l.contains("expect(")
            || l.contains("verify(") || l.contains(".shouldbe") || l.contains("require(")
    }

    private static func looksLikeNoOpAssertion(_ line: String) -> Bool {
        let l = line.replacingOccurrences(of: " ", with: "").lowercased()
        if l.contains("asserttrue(true)") || l.contains("assert(true)") || l.contains("expect(true)") { return true }
        // assertEquals(x, x) — same arg twice
        if let m = l.range(of: #"assert(equals|equal)?\(([a-z0-9_."]+),\2\)"#, options: .regularExpression) {
            _ = m; return true
        }
        return false
    }

    private static func looksLikeSkip(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("@ignore") || l.contains("@disabled") || l.contains("@pytest.mark.skip")
            || l.contains("#[ignore]") || l.contains("xit(") || l.contains("it.skip") || l.contains(".skip(")
            || l.contains("xctskip") || l.contains("@test(.disabled")
    }

    private static func looksLikeTestCase(_ line: String) -> Bool {
        let l = line
        // JUnit/Kotlin @Test, Swift `func test…`, XCTest, JS `it(`/`test(`, pytest `def test_`
        if l.range(of: #"@Test\b"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"func\s+test[A-Z0-9_]"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"\bdef\s+test_"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"\b(it|test)\s*\("#, options: .regularExpression) != nil { return true }
        if l.range(of: #"#\[test\]"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Glob matching

    private static func matches(_ path: String, _ regex: String) -> Bool {
        path.range(of: regex, options: .regularExpression) != nil
    }

    /// Converts a glob (`**`, `*`, `?`) into an anchored regex. `**` crosses `/`, `*` does not.
    /// `**/` matches zero-or-more leading path segments (so `**/src/test/**/*.kt` also matches a
    /// root-level `src/test/.../Foo.kt`), while a bare/trailing `**` matches anything.
    static func globToRegex(_ glob: String) -> String {
        var re = "^"
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    if i + 2 < chars.count && chars[i + 2] == "/" {
                        re += "(?:.*/)?"; i += 2             // **/ → zero-or-more segments
                    } else {
                        re += ".*"; i += 1                   // bare/trailing ** → anything incl /
                    }
                } else {
                    re += "[^/]*"                            // * → any non-slash
                }
            case "?": re += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                re += "\\\(c)"
            default: re += String(c)
            }
            i += 1
        }
        re += "$"
        return re
    }
}
