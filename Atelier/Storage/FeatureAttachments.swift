// SPDX-License-Identifier: MIT
import Foundation

/// Feature-level attachment store: files the user shares during the Brief stage
/// (mockups, spec PDFs, screenshots) persist here so they survive the chat and can
/// be ROUTED to the tasks that need them at decompose time.
///
/// Layout piggybacks on the task-attachment convention —
/// `<projectRoot>/.atelier/attachments/feature-<featureId>/<file>` — so the same
/// gitignore and `AttachmentService` plumbing apply. Once decompose assigns a file
/// to a task, it is COPIED into that task's own folder (the worker's spawn already
/// delivers task attachments via `--add-dir` + the `## Attachments` prompt section).
enum FeatureAttachments {
    /// The pseudo task-id under `.atelier/attachments/` for a feature's shared files.
    static func dirName(featureId: String) -> String { "feature-\(featureId)" }

    static func directory(projectRoot: String, featureId: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".atelier", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(dirName(featureId: featureId), isDirectory: true)
    }

    /// Copies a user file into the feature store, REPLACING any same-named file.
    /// Replace-by-name (unlike task attachments' collision suffixing) because this is
    /// a persistent, user-curated store: re-sharing an updated `mockup.png` must not
    /// leave a stale `mockup.png` beside a `mockup-2.png` for the decomposer to route.
    /// Also guarantees basenames are unique within the store. Returns the stored URL.
    @discardableResult
    static func store(sourceURL: URL, featureId: String, projectRoot: String) throws -> URL {
        let existing = list(projectRoot: projectRoot, featureId: featureId)
        if let stale = existing.first(where: {
            $0.lastPathComponent.lowercased() == sourceURL.lastPathComponent.lowercased()
        }) {
            try? FileManager.default.removeItem(at: stale)
        }
        let relative = try AttachmentService.attach(sourceURL: sourceURL,
                                                    taskId: dirName(featureId: featureId),
                                                    projectRoot: projectRoot)
        return AttachmentService.absoluteURL(relativePath: relative, projectRoot: projectRoot)
            .resolvingSymlinksInPath()   // canonical (/var vs /private/var) so URLs compare equal
    }

    /// All files currently in the feature store, sorted by name. Empty if none.
    static func list(projectRoot: String, featureId: String) -> [URL] {
        let dir = directory(projectRoot: projectRoot, featureId: featureId)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Per-file resolvingSymlinksInPath (not a one-shot dir resolve): NSURL's quirky
        // /private-stripping makes that the only form that compares EQUAL to store()'s
        // return — required for row identity/removal. Cost is microseconds for a handful
        // of files.
        return urls.filter { !$0.hasDirectoryPath }
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Basenames that appear more than once in `files` (case-insensitive). Non-empty only
    /// for externally-supplied source lists (the feature store itself is unique-by-name);
    /// such duplicates are unroutable beyond the first and must be surfaced as a warning.
    static func duplicateBasenames(in files: [URL]) -> [String] {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for f in files {
            let name = f.lastPathComponent.lowercased()
            if !seen.insert(name).inserted { dupes.insert(name) }
        }
        return dupes.sorted()
    }

    /// Removes the whole feature store directory (feature deletion cleanup).
    static func removeAll(projectRoot: String, featureId: String) {
        try? FileManager.default.removeItem(at: directory(projectRoot: projectRoot, featureId: featureId))
    }

    static func remove(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Resolves decomposer-assigned attachment NAMES to stored files, case-insensitively
    /// by filename (tolerates a stray path prefix the model might echo back).
    static func match(names: [String], in files: [URL]) -> [URL] {
        var out: [URL] = []
        for raw in names {
            let wanted = (raw as NSString).lastPathComponent.lowercased()
            guard !wanted.isEmpty else { continue }
            if let hit = files.first(where: { $0.lastPathComponent.lowercased() == wanted }),
               !out.contains(hit) {
                out.append(hit)
            }
        }
        return out
    }
}
