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
///
/// User-facing name: **"Mode"**. A mode also carries `build` (build/test commands)
/// which feeds the strict TDD gate and the Fill Kanban decomposition prompt.
///
/// **Adding a mode** (iOS, web, …) is one new `catalog` entry with its `build:`
/// block + a `Resources/Skills/profiles/<id>/` skill folder — no other code:
///   - iOS:  `xcodebuild build/test -destination 'platform=iOS Simulator'`
///   - web:  `pnpm build` / `pnpm test -- --run` (Vitest non-watch)
struct ProjectProfile: Identifiable, Hashable, Sendable {
    let id: String                     // stable, persisted in Project.profileId
    let name: String                   // human label
    let iconSystemName: String         // SF Symbol
    let defaultModel: String           // Claude model id
    let suggestedLabels: [String]
    let description: String            // one-line tooltip
    let defaultRules: [PermissionRule] // safe read-only allows pre-baked
    /// Build & test commands for the mode. Defaults to `.none`, so profiles
    /// without a configured toolchain keep compiling and behave unchanged.
    var build: BuildConfig = .none

    /// Per-mode build/test configuration. `testCommands` is what Atelier runs in a
    /// worktree to gate the TDD flow; `buildCommand` is an optional compile check.
    struct BuildConfig: Hashable, Sendable {
        var buildCommand: String?               // e.g. "./gradlew assembleDebug" — nil = no build gate
        var testCommands: [TestCommand]         // exit 0 of all .fast = green
        var testScaffoldingHint: String?        // one line injected into decompose + worker prompts
        var testDiscoveryGlobs: [String]        // proves a test setup exists (else → scaffold)
        var requiredTools: [ToolRequirement] = [] // toolchain that must be present to run build/test
        /// Optional INFORMATIONAL coverage command (e.g. `dotnet test --collect:"XPlat Code Coverage"`).
        /// Never a gate — run best-effort at dossier time to fill the recette's coverage line. nil = none.
        var coverageCommand: String? = nil
        /// SOFT coverage target (percent) the implementation AIMS for — woven into the decompose +
        /// worker prompts and the final synthesis. NEVER a merge gate: below target only PROPOSES a
        /// test-improvement round. nil here falls back to 90 whenever a `coverageCommand` exists
        /// (see `coverageTarget`), so any mode that can measure coverage gets the ≥90% aim for free.
        var coverageTargetPct: Int? = nil
        /// How to DETECT existing coverage tooling and, if missing, WIRE it. When set, the
        /// feature-flow prerequisites step offers a one-time, opt-in setup (its own commit) so
        /// `coverage_get` / the dossier have a real report to read. nil = no known setup for the mode
        /// (or it's built-in and needs none). Detection ≠ mutation: setup is only ever applied on
        /// explicit user opt-in.
        var coverageSetup: CoverageSetup? = nil
        static let none = BuildConfig(buildCommand: nil, testCommands: [], testScaffoldingHint: nil,
                                      testDiscoveryGlobs: [], requiredTools: [])

        /// The effective soft coverage aim: the explicit `coverageTargetPct`, else 90% when the mode
        /// can measure coverage at all (`coverageCommand != nil`), else nil (mode can't measure it).
        var coverageTarget: Int? { coverageTargetPct ?? (coverageCommand != nil ? 90 : nil) }

        /// Commands that gate review/merge by default — fast, no device required.
        var fastTestCommands: [TestCommand] { testCommands.filter { $0.tier == .fast } }
        /// Tools that must be present for the gate to even run (vs optional device tooling).
        var requiredToolsForGate: [ToolRequirement] { requiredTools.filter { $0.required } }
    }

    /// Per-mode coverage-tooling enablement: how to detect whether coverage is already
    /// wired, and self-contained instructions for a worker to wire it if not.
    struct CoverageSetup: Hashable, Sendable {
        /// Config filenames (matched by suffix) to scan for `markers`.
        var probeFiles: [String]     // e.g. ["build.gradle", "build.gradle.kts"]
        /// If any marker (case-insensitive substring) appears in any probe file, coverage is wired.
        var markers: [String]        // e.g. ["jacoco"]
        /// Human label for the tool (UI callout), e.g. "JaCoCo".
        var toolName: String
        /// Self-contained instructions appended to a setup worker's prompt.
        var instructions: String
    }

    struct TestCommand: Hashable, Sendable, Identifiable {
        var id: String          // "unit", "instrumented"
        var label: String       // "JVM unit tests"
        var command: String     // "./gradlew testDebugUnitTest"
        var tier: Tier          // .fast gates by default; .optional = device/slow, opt-in
        var requiresDevice: Bool
        enum Tier: Hashable, Sendable { case fast, optional }
    }

    /// A toolchain prerequisite for a mode (so Atelier can tell "tooling missing" from "tests red").
    struct ToolRequirement: Hashable, Sendable, Identifiable {
        var id: String          // "jdk", "android-sdk", "gradlew"
        var label: String       // "Java JDK"
        var probe: Probe
        var installHint: String // how to install / configure
        var required: Bool      // required to gate; false = optional (e.g. emulator for instrumented)

        enum Probe: Hashable, Sendable {
            case executable(String)        // resolvable as a command (matches how the test subprocess runs)
            case fileInProject(String)     // relative path exists in the project root
            case androidSdk                // ANDROID_HOME/ANDROID_SDK_ROOT / default location / local.properties
            case dotnetSdk                 // a `dotnet` host is resolvable AND an SDK major ≥ 8 (8.x/10.x) is installed
        }
    }

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

    // Shared Python toolchain (plain python + django + fastapi): pytest gate + coverage.py.
    private static let pythonRules: [PermissionRule] = [
        .init(tool: "Bash", pattern: "re:^(ruff|mypy|pytest|black|isort|coverage)( |$)", behavior: .allow, reason: "Python lint/test/coverage toolchain", scope: .profile),
        .init(tool: "Bash", pattern: "re:^python3? -m (pytest|mypy|ruff|coverage)( |$)", behavior: .allow, reason: "Python module invocations", scope: .profile),
        .init(tool: "Bash", pattern: "re:^python3? manage\\.py (test|check|migrate|makemigrations)( |$)", behavior: .allow, reason: "Django manage.py", scope: .profile),
    ]
    private static let pythonBuild = BuildConfig(
        buildCommand: nil,
        testCommands: [.init(id: "unit", label: "pytest", command: "pytest", tier: .fast, requiresDevice: false)],
        testScaffoldingHint: "Unit tests run with `pytest` — write the failing test FIRST. Tests live in tests/ or as test_*.py / *_test.py. If there's no test setup, create tests/ and ensure pytest is available. Django: pytest needs DJANGO_SETTINGS_MODULE (pytest-django); if unconfigured, `python manage.py test` is the fallback runner.",
        testDiscoveryGlobs: ["**/test_*.py", "**/*_test.py", "**/tests/**/*.py"],
        requiredTools: [
            .init(id: "python", label: "Python 3", probe: .executable("python3"),
                  installHint: "Install Python 3 (python3 must be runnable).", required: true),
            .init(id: "pytest", label: "pytest", probe: .executable("pytest"),
                  installHint: "Install pytest (`pip install pytest`) — the gate runs `pytest`. If it lives in a venv, activate it so `pytest` resolves.", required: true),
        ],
        coverageCommand: "pytest --cov --cov-report=xml",
        coverageSetup: .init(
            probeFiles: ["pyproject.toml", "setup.cfg", "pytest.ini", ".coveragerc", "tox.ini", "requirements.txt", "requirements-dev.txt"],
            markers: ["pytest-cov", "pytest_cov", "--cov", "coverage.py", "[tool.coverage", "[coverage:run]"],
            toolName: "pytest-cov",
            instructions: """
            Wire coverage.py so tests emit a Cobertura XML report. Do this and NOTHING else — no app/test code changes.
            - Add pytest-cov to the project's dev dependencies (pyproject `[project.optional-dependencies]`/`[tool.poetry.group.dev.dependencies]`, or requirements-dev.txt), so `pytest --cov` works.
            - Verify: `pytest --cov --cov-report=xml` exits 0 and writes `coverage.xml` (Cobertura) at the project root.
            - Commit ONLY the dependency/config change.
            """))

    // Shared JS/TS toolchain (node-backend + web-nextjs + react-vite). The gate runs the
    // project's own `npm test` script (portable across vitest/jest/etc); coverage is wire-able.
    private static let jsRules: [PermissionRule] = [
        .init(tool: "Bash", pattern: "re:^(pnpm|yarn|npm)( run)? (lint|typecheck|type-check|build|test|coverage|install|ci)( |$)", behavior: .allow, reason: "Standard JS package scripts", scope: .profile),
        .init(tool: "Bash", pattern: "re:^npx (tsc|vitest|jest|c8|nyc)( |$)", behavior: .allow, reason: "JS test/coverage/type tools", scope: .profile),
        .init(tool: "Bash", pattern: "re:^node (--version|--test)( |$)", behavior: .allow, reason: "Node runtime", scope: .profile),
    ]
    private static let jsBuild = BuildConfig(
        buildCommand: nil,
        testCommands: [.init(id: "unit", label: "npm test", command: "npm test", tier: .fast, requiresDevice: false)],
        testScaffoldingHint: "The gate runs `npm test` — ensure package.json has a real `test` script (e.g. \"vitest run\" or \"jest\") and that unit tests exist (write the failing test FIRST). Install deps first (npm/pnpm/yarn install) so the runner + node_modules are present; the npm default placeholder test script (exit 1) fails the gate until replaced.",
        testDiscoveryGlobs: ["**/*.test.ts", "**/*.test.tsx", "**/*.test.js", "**/*.spec.ts", "**/*.spec.js", "**/__tests__/**"],
        requiredTools: [
            .init(id: "node", label: "Node.js", probe: .executable("node"),
                  installHint: "Install Node.js (node must be runnable) — the gate runs `npm test`.", required: true),
        ],
        coverageSetup: .init(
            // No coverageCommand: JS test invocation is too project-specific to auto-run at dossier
            // time; coverage_get reads whatever report the worktree has. coverageSetup wires one.
            probeFiles: ["vitest.config.ts", "vitest.config.js", "vitest.config.mts", "vite.config.ts", "vite.config.js", "jest.config.js", "jest.config.ts", "package.json"],
            markers: ["@vitest/coverage-v8", "coverage-v8", "collectcoverage", "--coverage", "\"coverage\""],
            toolName: "Vitest coverage",
            instructions: """
            Wire test coverage so a report is produced under coverage/ (lcov.info + coverage-summary.json). Do this and NOTHING else — no app/test changes.
            - Prefer Vitest: add @vitest/coverage-v8 as a devDependency and configure `test.coverage` with reporter ['lcov','json-summary'] in the vite/vitest config; add a `coverage` script running the test runner with --coverage. For Jest projects, enable collectCoverage with coverageReporters ['lcovonly','json-summary'] instead.
            - Verify the coverage report files (coverage/lcov.info and/or coverage/coverage-summary.json) are produced. Commit ONLY the config / devDependency change.
            """))

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
            description: "package.json declares `next` (or a non-Vite React/Vue/Svelte/etc. frontend).",
            defaultRules: baseReadOnlyRules + jsRules,
            build: jsBuild
        ),
        .init(
            id: "react-vite",
            name: "React (Vite)",
            iconSystemName: "atom",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["frontend", "react", "vite", "typescript"],
            description: "React + TypeScript on Vite — package.json has react + vite and NOT next.",
            defaultRules: baseReadOnlyRules + jsRules,
            build: jsBuild
        ),
        .init(
            id: "node-backend",
            name: "Node.js backend",
            iconSystemName: "server.rack",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["backend", "node", "api"],
            description: "package.json without a frontend framework — Express/Fastify/etc.",
            defaultRules: baseReadOnlyRules + jsRules,
            build: jsBuild
        ),
        .init(
            id: "django",
            name: "Django",
            iconSystemName: "cube.transparent",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["python", "django", "web"],
            description: "Django web project — manage.py plus a `django` dependency.",
            defaultRules: baseReadOnlyRules + pythonRules,
            build: pythonBuild
        ),
        .init(
            id: "fastapi",
            name: "FastAPI",
            iconSystemName: "bolt.horizontal",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["python", "fastapi", "api"],
            description: "FastAPI service — a `fastapi` dependency in pyproject.toml / requirements.",
            defaultRules: baseReadOnlyRules + pythonRules,
            build: pythonBuild
        ),
        .init(
            id: "python",
            name: "Python",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            defaultModel: "claude-sonnet-4-6",
            suggestedLabels: ["python", "backend"],
            description: "pyproject.toml, setup.py, setup.cfg, requirements.txt, or Pipfile.",
            defaultRules: baseReadOnlyRules + pythonRules,
            build: pythonBuild
        ),
        .init(
            id: "rust",
            name: "Rust",
            iconSystemName: "gearshape.2",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["rust", "systems"],
            description: "Cargo.toml at the project root.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^cargo (check|build|test|clippy|fmt|tree|llvm-cov)( |$)", behavior: .allow, reason: "Standard cargo subcommands", scope: .profile),
            ],
            build: .init(
                buildCommand: "cargo build",
                testCommands: [.init(id: "unit", label: "cargo test", command: "cargo test", tier: .fast, requiresDevice: false)],
                testScaffoldingHint: "Rust unit tests live in `#[cfg(test)] mod tests` blocks next to the code; integration tests in tests/. Run with `cargo test` — write the failing test FIRST.",
                testDiscoveryGlobs: ["**/tests/**/*.rs", "**/src/**/*.rs"],
                requiredTools: [
                    .init(id: "cargo", label: "Cargo (Rust)", probe: .executable("cargo"),
                          installHint: "Install Rust via rustup (https://rustup.rs) — cargo must be runnable.", required: true),
                    .init(id: "cargo-llvm-cov", label: "cargo-llvm-cov (coverage, optional)", probe: .executable("cargo-llvm-cov"),
                          installHint: "Optional for coverage: `cargo install cargo-llvm-cov` + `rustup component add llvm-tools-preview`.", required: false),
                ],
                // Coverage is a global toolchain component (cargo-llvm-cov), not repo config —
                // no coverageSetup wiring; emits lcov, read by the multi-format parser.
                coverageCommand: "cargo llvm-cov --lcov --output-path lcov.info"
            )
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
                .init(tool: "Bash", pattern: "re:^gocover-cobertura( |<|$)", behavior: .allow, reason: "Go coverage → Cobertura", scope: .profile),
            ],
            build: .init(
                buildCommand: "go build ./...",
                testCommands: [.init(id: "unit", label: "go test", command: "go test ./...", tier: .fast, requiresDevice: false)],
                testScaffoldingHint: "Go tests are *_test.go files beside the code (func TestXxx(t *testing.T)); run with `go test ./...` — write the failing test FIRST.",
                testDiscoveryGlobs: ["**/*_test.go"],
                requiredTools: [
                    .init(id: "go", label: "Go toolchain", probe: .executable("go"),
                          installHint: "Install Go (https://go.dev/dl) — `go` must be runnable.", required: true),
                    .init(id: "gocover-cobertura", label: "gocover-cobertura (coverage, optional)", probe: .executable("gocover-cobertura"),
                          installHint: "Optional for coverage: `go install github.com/boumenot/gocover-cobertura@latest` (converts Go's coverprofile to Cobertura).", required: false),
                ],
                // Go's native coverprofile isn't parseable — convert to Cobertura via gocover-cobertura
                // (a global tool, not repo config → no coverageSetup).
                coverageCommand: "go test ./... -coverprofile=coverage.out -covermode=atomic && gocover-cobertura < coverage.out > coverage.xml"
            )
        ),
        .init(
            id: "android-kotlin",
            name: "Android / Kotlin",
            iconSystemName: "smartphone",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["android", "kotlin", "compose"],
            description: "build.gradle.kts / settings.gradle.kts / AndroidManifest.xml.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^\\./gradlew (assembleDebug|test|testDebugUnitTest|connectedDebugAndroidTest|lint|build|tasks|projects|dependencies)( |$)", behavior: .allow, reason: "Common gradle tasks", scope: .profile),
            ],
            build: .init(
                buildCommand: "./gradlew assembleDebug",
                testCommands: [
                    .init(id: "unit", label: "JVM unit tests",
                          command: "./gradlew testDebugUnitTest", tier: .fast, requiresDevice: false),
                    .init(id: "instrumented", label: "Instrumented tests",
                          command: "./gradlew connectedDebugAndroidTest", tier: .optional, requiresDevice: true),
                ],
                testScaffoldingHint: "Unit tests live in src/test/java|kotlin (JVM, JUnit + MockK, run by ./gradlew testDebugUnitTest). Instrumented/UI tests live in src/androidTest and need a device/emulator. Write JVM unit tests FIRST; add an instrumented test only when the change is UI/integration a JVM test can't cover. If no test source set exists, create src/test/java/<pkg>/ and add the JUnit/MockK test dependencies if missing.",
                testDiscoveryGlobs: ["**/src/test/**/*.kt", "**/src/test/**/*.java", "**/src/androidTest/**"],
                requiredTools: [
                    .init(id: "jdk", label: "Java JDK", probe: .executable("java"),
                          installHint: "Install a JDK 17+ (e.g. `brew install --cask temurin`) so Gradle can run.",
                          required: true),
                    .init(id: "android-sdk", label: "Android SDK", probe: .androidSdk,
                          installHint: "Install the Android SDK (Android Studio) and set ANDROID_HOME, or add `sdk.dir=…` to local.properties.",
                          required: true),
                    .init(id: "gradlew", label: "Gradle wrapper", probe: .fileInProject("gradlew"),
                          installHint: "This repo has no ./gradlew wrapper — run `gradle wrapper` in the project root.",
                          required: true),
                    .init(id: "adb", label: "adb / emulator (instrumented only)", probe: .executable("adb"),
                          installHint: "Needed only for `connectedDebugAndroidTest` (a running emulator/device). Optional for the JVM unit gate.",
                          required: false),
                ],
                coverageSetup: .init(
                    probeFiles: ["build.gradle", "build.gradle.kts"],
                    // Specific plugin-application / config tokens, not the bare word — a comment
                    // mentioning "jacoco" must NOT read as wired.
                    markers: ["id(\"jacoco\")", "id 'jacoco'", "apply plugin: 'jacoco'", "apply plugin: \"jacoco\"", "jacoco {"],
                    toolName: "JaCoCo",
                    instructions: """
                    Wire JaCoCo code coverage into this Android/Gradle project so a coverage XML report is produced for the JVM unit tests. Do this and NOTHING else — do not touch app code or existing tests.
                    - Apply the `jacoco` plugin in the app module's build.gradle(.kts).
                    - Add a `jacocoTestReport` task that depends on `testDebugUnitTest` and sets `reports { xml.required.set(true) }` (Groovy: `xml.required = true`), with class/source dirs for the `debug` variant. Exclude generated classes (R.class, BuildConfig, *_Impl, Hilt/Dagger, databinding).
                    - Verify: `./gradlew testDebugUnitTest jacocoTestReport` exits 0 AND an XML report exists under `**/build/reports/jacoco/**/*.xml` (or `jacocoTestReport.xml`).
                    - Commit ONLY the Gradle config changes (build.gradle(.kts), version catalog if used).
                    """)
            )
        ),
        .init(
            id: "dotnet",
            name: ".NET (C#)",
            iconSystemName: "number.square",
            defaultModel: ModelRouter.latestOpus,
            suggestedLabels: ["dotnet", "csharp"],
            description: "*.sln / *.slnx / *.csproj / *.fsproj / global.json / Directory.Build.props.",
            defaultRules: baseReadOnlyRules + [
                .init(tool: "Bash", pattern: "re:^dotnet (build|test|restore|run|format|new|sln|add|nuget|vstest|--list-sdks|--list-runtimes|--info|--version)( |$)", behavior: .allow, reason: "Common dotnet CLI commands", scope: .profile),
            ],
            build: .init(
                buildCommand: "dotnet build -c Debug",
                testCommands: [
                    .init(id: "unit", label: "Unit tests",
                          command: "dotnet test --nologo", tier: .fast, requiresDevice: false),
                ],
                testScaffoldingHint: "Unit tests live in a test project (xUnit/NUnit/MSTest) — typically *Tests.csproj / *.Tests.csproj or a test/ folder — and run with `dotnet test`. Write the failing test FIRST. If the repo has NO test project, scaffold one: `dotnet new xunit -o <Name>.Tests`, add a reference to the system-under-test (`dotnet add <Name>.Tests reference <Sut>.csproj`), and add it to the solution (`dotnet sln add`). The gate is `dotnet test` — it compiles the test project, which is fine; it is NOT a publish/app build.",
                testDiscoveryGlobs: ["**/*Tests/**/*.cs", "**/*.Tests/**/*.cs", "**/test/**/*.cs"],
                requiredTools: [
                    .init(id: "dotnet", label: ".NET SDK (8 or 10)", probe: .dotnetSdk,
                          installHint: "Install the .NET SDK 8 or 10 (https://dotnet.microsoft.com/download) — `dotnet` must be runnable.",
                          required: true),
                ],
                coverageCommand: "dotnet test --nologo --collect:\"XPlat Code Coverage\"",
                coverageSetup: .init(
                    probeFiles: [".csproj", ".fsproj", "Directory.Build.props", "Directory.Packages.props"],
                    markers: ["coverlet.collector", "coverlet.msbuild"],
                    toolName: "coverlet",
                    instructions: """
                    Ensure `dotnet test --collect:"XPlat Code Coverage"` produces a Cobertura report. Do this and NOTHING else — do not touch tests or app code.
                    - Add the `coverlet.collector` NuGet package to EACH test project that lacks it: `dotnet add <Test>.csproj package coverlet.collector`.
                    - Verify: `dotnet test --collect:"XPlat Code Coverage"` exits 0 and writes a `coverage.cobertura.xml` under `**/TestResults/**`.
                    - Commit ONLY the added package reference(s).
                    """)
            )
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
