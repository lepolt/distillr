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
        let baseOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        // Prefer the format's own embedded thumbnail/preview first (cheap —
        // for RAW specifically, the alternative is a full demosaic on every
        // decode) — but only trust it if it's actually big enough to satisfy
        // `maxPixelSize`. Confirmed by decoding a real 6048x4032 JPEG: most
        // plain JPEGs carry nothing but a tiny ~160x120 EXIF preview meant
        // for a camera's own LCD, and ...IfAbsent hands that straight back
        // with no upscaling — which is what was making every photo in
        // Review look low-resolution, not just RAW files. Falling back to a
        // full decode whenever the cheap path comes up short keeps the RAW
        // fast-path benefit without silently degrading everything else.
        var ifAbsentOptions = baseOptions
        ifAbsentOptions[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, ifAbsentOptions as CFDictionary),
           CGFloat(max(image.width, image.height)) >= maxPixelSize {
            return image
        }

        var alwaysOptions = baseOptions
        alwaysOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, alwaysOptions as CFDictionary)
    }
}
