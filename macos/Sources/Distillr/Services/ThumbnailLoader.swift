import CoreGraphics
import Foundation
import ImageIO

let thumbnailMaxSide: CGFloat = 200
// Large enough that Review/Compare display the image at native resolution
// on virtually any Mac display (including 2x Retina) without upscaling —
// upscaling a smaller decode is what was causing the blurry, "zoomed in"
// look in Compare mode.
let loupeMaxSide: CGFloat = 4000

/// Decodes a photo (JPEG or RAW — RAW via its embedded preview, not a real
/// demosaic) for display, downscaled to `maxPixelSize` and with EXIF
/// orientation already applied by ImageIO, so portrait shots come out
/// right-side up without any manual rotation. Returns `CGImage` rather than
/// `NSImage`: immutable and safe to hand across a background decode task,
/// and SwiftUI's `Image` accepts it directly.
enum ThumbnailLoader {
    static func decodeImage(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
