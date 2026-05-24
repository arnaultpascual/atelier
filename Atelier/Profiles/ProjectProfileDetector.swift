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

        // package.json — branch into web vs node
        if set.contains("package.json") {
            let pkg = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkg),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let deps = (obj["dependencies"] as? [String: Any]) ?? [:]
                let devDeps = (obj["devDependencies"] as? [String: Any]) ?? [:]
                let all = deps.merging(devDeps) { l, _ in l }
                let frontendKeys = ["next", "react", "vue", "svelte", "nuxt", "astro", "remix", "@angular/core"]
                if frontendKeys.contains(where: { all[$0] != nil }) {
                    return (profile(id: "web-nextjs"), ["package.json (frontend)"])
                }
                return (profile(id: "node-backend"), ["package.json"])
            }
            return (profile(id: "node-backend"), ["package.json"])
        }

        // Python
        let pyMarkers = ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"]
        let pyHits = pyMarkers.filter(set.contains)
        if !pyHits.isEmpty {
            return (profile(id: "python"), pyHits)
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

    private static func isCodeFile(_ name: String) -> Bool {
        let codeExts = [".swift", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".go",
                        ".rb", ".php", ".java", ".kt", ".c", ".cpp", ".h", ".m", ".mm"]
        return codeExts.contains(where: name.hasSuffix)
    }
}
