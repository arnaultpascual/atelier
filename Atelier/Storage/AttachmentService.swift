// SPDX-License-Identifier: MIT
import Foundation
import os
import UniformTypeIdentifiers

/// Manages task attachments on disk. Each task owns a folder under
/// `<projectRoot>/.atelier/attachments/<task-id>/` which is gitignored by default
/// (scaffolder appends `.atelier-worktrees/` and the audit log; attachments inherit
/// from the broader `.atelier/` gitignore).
enum AttachmentService {
    private static let logger = Logger(subsystem: "app.atelier", category: "attachments")

    enum Error: Swift.Error, LocalizedError {
        case sourceMissing(String)
        case copyFailed(String, underlying: Swift.Error)
        case removeFailed(String, underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let p): return "Source file not found: \(p)"
            case .copyFailed(let p, let u): return "Could not copy \(p): \(u.localizedDescription)"
            case .removeFailed(let p, let u): return "Could not remove \(p): \(u.localizedDescription)"
            }
        }
    }

    /// Copies `sourceURL` into the task's attachment folder, returning the relative
    /// path (relative to the project root) suitable for storage in `Task.attachments`.
    /// Handles filename collisions by suffixing `-2`, `-3`, ...
    @discardableResult
    static func attach(sourceURL: URL, taskId: String, projectRoot: String) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw Error.sourceMissing(sourceURL.path)
        }

        let attachmentsDir = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".atelier", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(taskId, isDirectory: true)
        try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        let original = sourceURL.lastPathComponent
        var dest = attachmentsDir.appendingPathComponent(original)
        var counter = 2
        let baseStem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        while fm.fileExists(atPath: dest.path) {
            let candidate = ext.isEmpty
                ? "\(baseStem)-\(counter)"
                : "\(baseStem)-\(counter).\(ext)"
            dest = attachmentsDir.appendingPathComponent(candidate)
            counter += 1
        }

        do {
            try fm.copyItem(at: sourceURL, to: dest)
        } catch {
            throw Error.copyFailed(sourceURL.path, underlying: error)
        }

        let relative = ".atelier/attachments/\(taskId)/\(dest.lastPathComponent)"
        logger.info("attached \(relative, privacy: .public)")
        return relative
    }

    /// Removes the attachment file. Safe to call if the file no longer exists.
    static func detach(relativePath: String, projectRoot: String) throws {
        let absolute = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(relativePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: absolute.path) else { return }
        do {
            try fm.removeItem(at: absolute)
        } catch {
            throw Error.removeFailed(absolute.path, underlying: error)
        }
        logger.info("detached \(relativePath, privacy: .public)")
    }

    /// Returns the absolute URL for a stored attachment path.
    static func absoluteURL(relativePath: String, projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
    }

    // MARK: - Metadata helpers

    struct Info: Sendable, Hashable {
        let relativePath: String
        let filename: String
        let sizeBytes: Int64
        let contentType: UTType?
        let exists: Bool

        var displaySize: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
        var isImage: Bool { contentType?.conforms(to: .image) ?? false }
        var iconSymbol: String {
            guard let ct = contentType else { return "doc" }
            if ct.conforms(to: .image) { return "photo" }
            if ct.conforms(to: .pdf) { return "doc.richtext" }
            if ct.conforms(to: .movie) { return "film" }
            if ct.conforms(to: .audio) { return "waveform" }
            if ct.conforms(to: .sourceCode) || ct.conforms(to: .plainText) { return "doc.text" }
            if ct.conforms(to: .archive) { return "doc.zipper" }
            return "doc"
        }
    }

    static func info(relativePath: String, projectRoot: String) -> Info {
        let absolute = absoluteURL(relativePath: relativePath, projectRoot: projectRoot)
        let filename = (relativePath as NSString).lastPathComponent
        let fm = FileManager.default
        guard fm.fileExists(atPath: absolute.path) else {
            return Info(relativePath: relativePath,
                        filename: filename,
                        sizeBytes: 0,
                        contentType: nil,
                        exists: false)
        }
        let attrs = (try? fm.attributesOfItem(atPath: absolute.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let utType: UTType? = {
            let ext = (filename as NSString).pathExtension
            return ext.isEmpty ? nil : UTType(filenameExtension: ext)
        }()
        return Info(relativePath: relativePath,
                    filename: filename,
                    sizeBytes: size,
                    contentType: utType,
                    exists: true)
    }
}
