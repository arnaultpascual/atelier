// SPDX-License-Identifier: MIT
import Foundation

/// Lightweight project archetype. The catalog is static for now; future
/// versions could surface user-defined profiles in Settings.
///
/// A profile suggests:
///   - `defaultModel`: what model new tasks should default to
///   - `suggestedLabels`: pre-populated labels users can pin to backlog tasks
///   - `iconSystemName`: SF Symbol shown in the sidebar / project header
///   - `defaultRules`: baked permission rules — safe, read-only stuff that
///     should never have to interrupt the human (Read inside the worktree,
///     Grep, Glob, language-specific build/test commands).
///
/// **Detection** lives in `ProjectProfileDetector`. It scans for marker files
/// (package.json, Cargo.toml, *.xcodeproj, …) and returns a best-fit profile.
struct ProjectProfile: Identifiable, Hashable, Sendable {
    let id: String                     // stable, persisted in Project.profileId
    let name: String                   // human label
    let iconSystemName: String         // SF Symbol
    let defaultModel: String           // Claude model id
    let suggestedLabels: [String]
    let description: String            // one-line tooltip
    let defaultRules: [PermissionRule] // safe read-only allows pre-baked

    // Common rules every profile inherits — read-only filesystem queries
    // inside the worktree, file globbing, grepping.
    private static let baseReadOnlyRules: [PermissionRule] = [
        .init(tool: "Read", pattern: "$WORKTREE/**", behavior: .allow, reason: "Read inside the worktree", scope: .profile),
        .init(tool: "Read", pattern: "$PROJECT/**", behavior: .allow, reason: "Read inside the project root", scope: .profile),
        .init(tool: "Glob", pattern: nil, behavior: .allow, reason: "File globbing is read-only", scope: .profile),
        .init(tool: "Grep", pattern: nil, behavior: .allow, reason: "Grep is read-only", scope: .profile),
        .init(tool: "Bash", pattern: "re:^git (status|diff|log|branch|show|fetch|remote|rev-parse|ls-files)( |$)", behavior: .allow, reason: "Read-only git inspection", scope: .profile),
        .init(tool: "Bash", pattern: "re:^(ls|pwd|cat|head|tail|wc|find|tree|file|stat)( |$)", behavior: .allow, reason: "Read-only POSIX inspection", scope: .profile),
    ]

    static let catalog: [ProjectProfile] = [
        .init(
            id: "swift-apple",
            name: "Swift / Apple platforms",
            iconSystemName: "swift",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["ios", "macos", "swiftui"],
            description: "Detected via Package.swift, *.xcodeproj, or *.xcworkspace.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^swift (build|test|package)( |$)", behavior: .allow, reason: "Swift PM commands", scope: .profile),
                .init(tool: "Bash", pattern: "re:^xcodebuild .*build( |$)", behavior: .allow, reason: "xcodebuild build", scope: .profile),
                .init(tool: "Bash", pattern: "re:^xcrun ", behavior: .allow, reason: "xcrun developer tools", scope: .profile),
            ]
        ),
        .init(
            id: "web-nextjs",
            name: "Next.js / React",
            iconSystemName: "globe",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["frontend", "next", "react"],
            description: "package.json declares `next`, `react`, or `react-dom`.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^(pnpm|yarn|npm) (run )?(lint|typecheck|build|test)", behavior: .allow, reason: "Standard npm scripts", scope: .profile),
                .init(tool: "Bash", pattern: "re:^npx tsc( |$)", behavior: .allow, reason: "TypeScript type-check", scope: .profile),
            ]
        ),
        .init(
            id: "node-backend",
            name: "Node.js backend",
            iconSystemName: "server.rack",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["backend", "node", "api"],
            description: "package.json without a frontend framework — Express/Fastify/etc.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^(pnpm|yarn|npm) (run )?(lint|typecheck|build|test)", behavior: .allow, reason: "Standard npm scripts", scope: .profile),
                .init(tool: "Bash", pattern: "re:^node --version$", behavior: .allow, reason: "Node version check", scope: .profile),
            ]
        ),
        .init(
            id: "python",
            name: "Python",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["python", "backend"],
            description: "pyproject.toml, setup.py, or requirements.txt.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^(ruff|mypy|pytest|black|isort)( |$)", behavior: .allow, reason: "Python lint/test toolchain", scope: .profile),
                .init(tool: "Bash", pattern: "re:^python -m (pytest|mypy|ruff)( |$)", behavior: .allow, reason: "Python module invocations", scope: .profile),
            ]
        ),
        .init(
            id: "rust",
            name: "Rust",
            iconSystemName: "gearshape.2",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["rust", "systems"],
            description: "Cargo.toml at the project root.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^cargo (check|build|test|clippy|fmt|tree)( |$)", behavior: .allow, reason: "Standard cargo subcommands", scope: .profile),
            ]
        ),
        .init(
            id: "go",
            name: "Go",
            iconSystemName: "hare",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["go", "backend"],
            description: "go.mod at the project root.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^go (build|test|vet|fmt|mod|run|env)( |$)", behavior: .allow, reason: "Standard go subcommands", scope: .profile),
                .init(tool: "Bash", pattern: "re:^gofmt ", behavior: .allow, reason: "gofmt", scope: .profile),
            ]
        ),
        .init(
            id: "android-kotlin",
            name: "Android / Kotlin",
            iconSystemName: "smartphone",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["android", "kotlin", "compose"],
            description: "build.gradle.kts / settings.gradle.kts / AndroidManifest.xml.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^\\./gradlew (assembleDebug|test|lint|build|tasks|projects)( |$)", behavior: .allow, reason: "Common gradle tasks", scope: .profile),
            ]
        ),
        .init(
            id: "docs",
            name: "Documentation",
            iconSystemName: "doc.text",
            defaultModel: "claude-haiku-4-5-20251001",
            suggestedLabels: ["docs"],
            description: "Mostly markdown — no executable code markers found.",
            defaultRules: baseReadOnlyRules
        ),
        .init(
            id: "generic",
            name: "Generic",
            iconSystemName: "folder",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: [],
            description: "No specific markers detected — defaulting to Sonnet.",
            defaultRules: baseReadOnlyRules
        )
    ]

    static func find(id: String?) -> ProjectProfile? {
        guard let id else { return nil }
        return catalog.first(where: { $0.id == id })
    }

    static var generic: ProjectProfile { catalog.last! }
}
