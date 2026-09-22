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
            // ...IfAbsent, not ...Always: prefer the format's own embedded
            // thumbnail/preview when one exists (which RAW files generally
            // carry), only falling back to a full decode when a file
            // genuinely lacks one. ...Always forces ImageIO to regenerate
            // from the full image every time, which for RAW means a full
            // demosaic on every decode instead of just reading the
            // embedded preview — exactly what this function's own doc
            // comment above says it avoids.
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
