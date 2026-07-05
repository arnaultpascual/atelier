// SPDX-License-Identifier: MIT
import Foundation

/// Scans a project root for marker files and picks the best-fit
/// `ProjectProfile`. Cheap — only reads the top-level directory listing and
/// then `package.json` if present (for the Next.js vs Node.js fork).
///
/// Order matters: the first matching rule wins.
enum ProjectProfileDetector {
    /// Returns `(profile, hits)` where `hits` is the list of marker filenames
    /// that drove the decision (for UI explanations).
    static func detect(at path: String) -> (profile: ProjectProfile, hits: [String]) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let set = Set(entries)

        // Android — gradle markers are highly specific, check before Java/Kotlin-y stuff
        let androidMarkers = ["AndroidManifest.xml", "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle"]
        let androidHits = androidMarkers.filter(set.contains)
        if androidHits.contains(where: { $0.contains("AndroidManifest") })
            || (androidHits.count >= 2 && (set.contains("app") || set.contains("gradle.properties"))) {
            return (profile(id: "android-kotlin"), androidHits)
        }

        // Swift / Apple
        let appleMarkers = entries.filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        if !appleMarkers.isEmpty || set.contains("Package.swift") {
            return (profile(id: "swift-apple"),
                    appleMarkers + (set.contains("Package.swift") ? ["Package.swift"] : []))
        }

        // .NET (C#/F#) — solution/project files & build markers (top-level, like the others)
        let dotnetSuffixes = [".sln", ".slnx", ".csproj", ".fsproj"]
        let dotnetMarkerFiles = ["global.json", "Directory.Build.props"]
        let dotnetHits = entries.filter { e in dotnetSuffixes.contains(where: e.hasSuffix) }
            + dotnetMarkerFiles.filter(set.contains)
        if !dotnetHits.isEmpty {
            return (profile(id: "dotnet"), dotnetHits)
        }

        // package.json — branch into web vs node
        if set.contains("package.json") {
            let pkg = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkg),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = (obj["dependencies"] as? [String: Any]) ?? [:]
                let devDeps = (obj["devDependencies"] as? [String: Any]) ?? [:]
                let all = deps.merging(devDeps) { l, _ in l }
                let frontendKeys = ["next", "react", "vue", "svelte", "nuxt", "astro", "remix", "@angular/core"]
                // Order inside the fork is load-bearing: next → react+vite → other frontend → node.
                if all["next"] != nil {
                    return (profile(id: "web-nextjs"), ["package.json (next)"])
                }
                if (all["react"] != nil || all["react-dom"] != nil)
                    && (all["vite"] != nil || all["@vitejs/plugin-react"] != nil) {
                    return (profile(id: "react-vite"), ["package.json (react+vite)"])
                }
                if frontendKeys.contains(where: { all[$0] != nil }) {
                    return (profile(id: "web-nextjs"), ["package.json (frontend)"])
                }
                return (profile(id: "node-backend"), ["package.json"])
            }
            return (profile(id: "node-backend"), ["package.json"])
        }

        // Python — django / fastapi sub-types first (need a dependency-manifest sniff),
        // then plain python as the fallback.
        let pyMarkers = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"]
        let pyHits = pyMarkers.filter(set.contains)
        if !pyHits.isEmpty || set.contains("manage.py") {
            let manifests = ["pyproject.toml", "requirements.txt", "requirements-dev.txt", "Pipfile", "setup.cfg"]
                .filter(set.contains).map { readText(url, $0) }.joined(separator: "\n")
            // Django: manage.py (strong signal) or a `django` dependency (token-boundary
            // match, so `django-cors-headers` / a comment substring don't false-trigger).
            if set.contains("manage.py") || mentionsDependency(manifests, "django") {
                return (profile(id: "django"), pyHits + (set.contains("manage.py") ? ["manage.py"] : []))
            }
            // FastAPI: a `fastapi` dependency (boundary match rejects `fastapi-utils` etc).
            if mentionsDependency(manifests, "fastapi") {
                return (profile(id: "fastapi"), pyHits + ["fastapi"])
            }
            if !pyHits.isEmpty { return (profile(id: "python"), pyHits) }
        }

        // Rust
        if set.contains("Cargo.toml") {
            return (profile(id: "rust"), ["Cargo.toml"])
        }

        // Go
        if set.contains("go.mod") {
            return (profile(id: "go"), ["go.mod"])
        }

        // Docs — README + many .md files, no code markers
        let mdFiles = entries.filter { $0.hasSuffix(".md") || $0.hasSuffix(".mdx") }
        if mdFiles.count >= 2 && !entries.contains(where: { isCodeFile($0) }) {
            return (profile(id: "docs"), mdFiles.prefix(3).map { $0 })
        }

        return (ProjectProfile.generic, [])
    }

    private static func profile(id: String) -> ProjectProfile {
        ProjectProfile.find(id: id) ?? ProjectProfile.generic
    }

    /// Reads a top-level file's contents (bounded, lowercased) for dependency sniffing.
    /// Returns "" if absent/unreadable.
    private static func readText(_ root: URL, _ name: String) -> String {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return "" }
        return String(decoding: data.prefix(200_000), as: UTF8.self).lowercased()
    }

    /// True if `text` (already lowercased) names `dep` at a dependency-token boundary — so
    /// `fastapi` matches `fastapi==0.1` / a bare line but NOT `fastapi-utils`, and `django`
    /// matches a real dep but not `django-cors-headers`.
    private static func mentionsDependency(_ text: String, _ dep: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "(^|[^a-z0-9_.-])\(dep)([^a-z0-9_.-]|$)") else {
            return text.contains(dep)
        }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isCodeFile(_ name: String) -> Bool {
        let codeExts = [".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".go",
                        ".rb", ".php", ".java", ".kt", ".c", ".cpp", ".h", ".m", ".mm",
                        ".cs", ".fs"]
        return codeExts.contains(where: name.hasSuffix)
    }
}
