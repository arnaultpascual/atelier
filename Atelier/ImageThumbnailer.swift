// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import ImageIO

/// Shared, cached image-thumbnail loader for attachment previews.
///
/// - `nonisolated` async: called with `await` from a MainActor `.task`, the decode hops
///   off the main actor automatically AND inherits the task's cancellation (unlike a
///   `Task.detached`, which would keep decoding after the row disappears).
/// - NSCache keyed by path+mtime: re-expanding a collapsed list is a dictionary hit,
///   not N full CGImageSource decodes.
enum ImageThumbnailer {
    // NSCache is documented thread-safe ("You can add, remove, and query items in the
    // cache from different threads") but not Sendable-annotated — hence the escape hatch.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// Downsampled thumbnail for an image file, or nil for non-images / failures.
    nonisolated static func thumbnail(at url: URL, maxPixel: Int = 64) async -> NSImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        let key = "\(url.path)|\(mtime)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard !Task.isCancelled,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard !Task.isCancelled,
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
