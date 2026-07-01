// SPDX-License-Identifier: MIT
import Foundation

/// The automatic end-of-feature deliverable, written at the PROJECT ROOT as `FEATURE-<slug>.md`.
/// Elevates the per-task `DossierBuilder` to the FEATURE level: one document with three sections —
/// (1) Technique (what was implemented, rolled up from the merged tasks + git diff), (2) Quality &
/// coverage (integration test re-run, final coverage vs target, conformity to the demand), and
/// (3) Manual tests (the recette a human must exercise, deduped across tasks).
///
/// Part A (run results, coverage, changed files, per-task outcomes) is assembled deterministically
/// in Swift; Part B (conformity verdict, criteria classification, manual checks, technical summary)
/// is one `AIAssistant.synthesizeFeature` pass. Best-effort: a failure still yields a useful Part A.
struct FeatureDeliverable: Sendable {
    let slug: String
    let title: String
    var costUsd: Double = 0
    let markdown: String

    static func build(integrationBranch: String,
                      baseBranch: String,
                      project: Project,
                      profile: ProjectProfile,
                      mergedTasks: [AtelierTask],
                      blockedTasks: [(task: AtelierTask, reason: String)],
                      stalledTasks: [AtelierTask],
                      reviewRollup: String,
                      testResult: TestRunner.Result?,
                      buildOutcome: TestRunner.CommandOutcome?,
                      coverage: String?,
                      apiKey: String?) async -> FeatureDeliverable {
        // ---- demand + acceptance criteria, aggregated across the merged tasks ----
        let demand = mergedTasks.map { t -> String in
            let body = (t.descriptionMd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "### \(t.title)\n\(body.isEmpty ? "(no description)" : body)"
        }.joined(separator: "\n\n")
        var acceptance: [String] = []
        for t in mergedTasks { acceptance.append(contentsOf: DossierBuilder.parseAcceptanceCriteria(t.descriptionMd ?? "")) }
        acceptance = dedupePreservingOrder(acceptance)

        // ---- changed files across the whole feature (integration branch vs its base) ----
        let diff = try? await GitService.runDiff(projectPath: project.path,
                                                 base: baseBranch, branch: integrationBranch)
        let changed = diff?.files ?? []
        let stat = diff?.stat

        // ---- coverage (pre-measured by the synthesis pass) + build status ----
        let buildStatus: String = {
            if let o = buildOutcome { return "\(o.command) → \(o.passed ? "PASS" : "FAIL")" }
            guard profile.build.buildCommand != nil || project.verifyBuildCommand != nil else { return "no build step" }
            return "not run (app build is opt-in)"
        }()

        // ---- Part B (LLM): conformity + criteria + manual checks + summary ----
        let content = try? await AIAssistant.synthesizeFeature(
            demand: demand,
            acceptanceCriteria: acceptance,
            changedFiles: changed.map(\.path),
            testSummary: (testResult?.ranAnything ?? false) ? (testResult?.summaryLine ?? "n/a") : "no automated tests for this mode",
            coverage: coverage,
            coverageTarget: profile.build.coverageTarget,
            buildStatus: buildStatus,
            reviewRollup: reviewRollup,
            baseBranch: baseBranch,
            projectPath: project.path,
            apiKey: apiKey)

        let resolvedTitle: String = {
            let t = content?.featureTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? "" : t
        }()
        let slug = BacklogMD.slugify(resolvedTitle.isEmpty ? integrationBranch : resolvedTitle)
        let displayTitle = resolvedTitle.isEmpty ? "Autopilot feature" : resolvedTitle
        let md = render(integrationBranch: integrationBranch, baseBranch: baseBranch,
                        project: project, profile: profile, title: displayTitle,
                        mergedTasks: mergedTasks, blockedTasks: blockedTasks, stalledTasks: stalledTasks,
                        changed: changed, stat: stat,
                        testResult: testResult, buildStatus: buildStatus, coverage: coverage,
                        content: content)
        return FeatureDeliverable(slug: slug, title: displayTitle, costUsd: content?.costUsd ?? 0, markdown: md)
    }

    // MARK: - Rendering (Part A deterministic, Part B from `content`)

    private static func render(integrationBranch: String,
                               baseBranch: String,
                               project: Project,
                               profile: ProjectProfile,
                               title: String,
                               mergedTasks: [AtelierTask],
                               blockedTasks: [(task: AtelierTask, reason: String)],
                               stalledTasks: [AtelierTask],
                               changed: [GitService.ChangedFile],
                               stat: GitService.DiffStat?,
                               testResult: TestRunner.Result?,
                               buildStatus: String,
                               coverage: String?,
                               content: AIAssistant.FeatureSynthesisContent?) -> String {
        var md = "# Feature — \(title)\n\n"
        md += "_Generated \(Date().formatted(date: .abbreviated, time: .shortened)) · integration branch `\(integrationBranch)` (from `\(baseBranch)`)_\n\n"
        md += "- **Tasks merged:** \(mergedTasks.count)"
        if !blockedTasks.isEmpty { md += " · **blocked:** \(blockedTasks.count)" }
        if !stalledTasks.isEmpty { md += " · **not run (blocked dep):** \(stalledTasks.count)" }
        if let stat, !stat.isEmpty { md += " · **diff:** \(stat.filesChanged) file\(stat.filesChanged == 1 ? "" : "s"), +\(stat.insertions)/−\(stat.deletions)" }
        md += "\n\n"

        // ---- 1. Technique ----
        md += "## 1. Technique — what was implemented\n\n"
        if let summary = content?.summary, !summary.isEmpty { md += "\(summary)\n\n" }
        md += "### Tasks\n"
        for t in mergedTasks {
            let dossier = TestDossierStore.exists(taskId: t.id, projectPath: project.path)
                ? " · [recette](.atelier/dossiers/\(t.id).md)" : ""
            md += "- ✅ **\(t.title)** (`\(t.id)`)\(dossier)\n"
        }
        for b in blockedTasks {
            md += "- ⛔️ **\(b.task.title)** (`\(b.task.id)`) — blocked: \(b.reason)\n"
        }
        for s in stalledTasks {
            md += "- ⏸️ **\(s.title)** (`\(s.id)`) — not run: waiting on a dependency that didn't finish\n"
        }
        md += "\n"
        if !changed.isEmpty {
            md += "### Changed files\n"
            for f in changed.prefix(80) { md += "- `\(f.path)` (\(f.status.label))\n" }
            if changed.count > 80 { md += "- …and \(changed.count - 80) more\n" }
            md += "\n"
        }

        // ---- 2. Quality & coverage ----
        md += "## 2. Quality & coverage\n\n"
        if let r = testResult, r.ranAnything {
            for c in r.perCommand { md += "- Tests: \(c.passed ? "✅" : "❌") `\(c.command)` (\(Int(c.duration))s)\n" }
            md += "- Suite: \(r.passed ? "green" : "RED") — \(r.summaryLine)\n"
        } else if let r = testResult, r.toolchainMissing {
            md += "- Tests: ⚠️ toolchain missing — \(r.summaryLine)\n"
        } else {
            md += "- Tests: _no automated test command for this mode (gate is informational)._\n"
        }
        if let coverage {
            let target = profile.build.coverageTarget
            let verdict = coverageVerdict(coverage, target: target)
            md += "- Coverage: \(coverage)\(verdict) — informational, never a gate\n"
        } else if let target = profile.build.coverageTarget {
            md += "- Coverage: not measured (aim was ≥ \(target)%)\n"
        }
        md += "- Build: \(buildStatus)\n"
        if let c = content {
            md += "\n### Conformity to the demand\n"
            md += "- **\(c.answersTheDemand ? "✅ Answers the demand" : "⚠️ Partial / gaps")** — \(c.conformityRationale)\n"
            for g in c.gaps { md += "  - Gap: \(g)\n" }
            if !c.criteria.isEmpty {
                md += "\n### Acceptance criteria\n"
                for crit in c.criteria {
                    let mark: String
                    switch crit.coverage.lowercased() {
                    case "automated": mark = "✅ automated"
                    case "partial":   mark = "🟡 partial"
                    default:           mark = "👤 manual"
                    }
                    md += "- \(mark) — \(crit.text)\(crit.evidence.isEmpty ? "" : " → \(crit.evidence)")\n"
                }
            }
        }
        md += "\n"

        // ---- 3. Manual tests ----
        md += "## 3. Manual tests — verify by hand in the running app\n\n"
        let checks = content?.manualChecks ?? []
        if checks.isEmpty {
            md += "_No functional checks identified — behavior appears fully guaranteed by code & tests. "
            md += "Still smoke-test the happy path before shipping._\n"
        } else {
            var idx = 0
            for c in checks {
                idx += 1
                md += "- [ ] **[\(c.category)] M-\(idx) — \(c.title)**\n"
                if !c.howTo.isEmpty { md += "      How: \(c.howTo)\n" }
                if !c.why.isEmpty { md += "      Why: \(c.why)\n" }
            }
        }
        md += "\n---\n_Per-task recette dossiers live under `.atelier/dossiers/`._\n"
        return md
    }

    // MARK: - Helpers

    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for i in items {
            let key = i.lowercased().trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && seen.insert(key).inserted { out.append(i) }
        }
        return out
    }

    /// Parses the first percentage out of a coverage string ("lines 84.2%, …") and renders a
    /// " · ≥90% ✅ / below 90%" note vs the soft target. Best-effort: unparseable → no note.
    private static func coverageVerdict(_ coverage: String, target: Int?) -> String {
        guard let target else { return "" }
        guard let pctRange = coverage.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression),
              let value = Double(coverage[pctRange].dropLast()) else { return "" }
        return value + 0.05 >= Double(target)
            ? " · ≥ \(target)% ✅"
            : " · below the ≥ \(target)% aim (a test-improvement round is suggested, not required)"
    }
}

/// Disk I/O for the feature deliverable — written at the PROJECT ROOT (not under `.atelier/`) so it
/// is an obvious, top-level artifact the user ships/reads, exactly as the spec asks.
enum FeatureDeliverableStore {
    static func url(slug: String, projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent("FEATURE-\(slug).md")
    }

    @discardableResult
    static func persist(_ deliverable: FeatureDeliverable, projectPath: String) -> URL {
        let url = url(slug: deliverable.slug, projectPath: projectPath)
        try? deliverable.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
