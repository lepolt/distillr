import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let thumbnailMaxSide: CGFloat = 200
// Large enough that Review/Compare display the image at native resolution
// on virtually any Mac display (including 2x Retina) without upscaling —
// upscaling a smaller decode is what was causing the blurry, "zoomed in"
// look in Compare mode.
let loupeMaxSide: CGFloat = 4000

/// Decodes a photo (JPEG or RAW) for display, downscaled to `maxPixelSize`
/// with EXIF orientation already applied by ImageIO, so portrait shots come
/// out right-side up without any manual rotation. Returns `CGImage` rather
/// than `NSImage`: immutable and safe to hand across a background decode
/// task, and SwiftUI's `Image` accepts it directly.
///
/// KNOWN ISSUE, shelved (not fixed): decoding a full-resolution JPEG here
/// (i.e. the loupe path, below) can log a harmless
/// "IOSurface creation failed" / "CMPhotoDecompressionContainer+JFIF"
/// warning to the console. Confirmed non-fatal — the image still decodes
/// and displays correctly despite it. Tried and ruled out as the cause:
/// concurrent decode pressure (serialized `prefetchLoupeNeighbors` in
/// AppModel so neighbors no longer race the current photo — no change)
/// and a redundant double decode call (removed entirely for JPEG/HEIC via
/// the RAW check below — no change). It still reproduces from a single,
/// isolated decode, which points at something inside ImageIO/CMPhoto
/// itself rather than anything in this call's own orchestration. Matches
/// widely-reported, Apple-unexplained forum threads describing the exact
/// same warning across unrelated apps and workloads. Parked rather than
/// actively worked; revisit only with real Console.app log access to
/// test against, not another guess.
enum ThumbnailLoader {
    /// `verifyResolution` controls whether the format's own embedded
    /// thumbnail/preview is trusted outright, or only used when it's
    /// actually as large as `maxPixelSize`:
    ///
    /// - `false` (grid thumbnails): always take the cheap embedded-preview
    ///   path. For RAW this avoids a full demosaic; for JPEG, the embedded
    ///   EXIF preview (~160x120 — a smaller re-render of the same image,
    ///   not a stale or unrelated one) is plenty for a small grid cell.
    ///   ImageIO already falls back to a full decode on its own whenever a
    ///   file genuinely has no embedded preview, so nothing is lost when
    ///   one happens to be missing.
    /// - `true` (Review/Compare's full-resolution loupe): verify the
    ///   embedded preview actually meets `maxPixelSize` before trusting
    ///   it, falling back to a full decode otherwise. Needed because most
    ///   plain JPEGs' embedded preview is far too small for a 4000px
    ///   loupe view — confirmed by decoding a real 6048x4032 JPEG and
    ///   getting exactly that tiny 160x120 preview back, unmodified.
    ///
    /// When `verifyResolution` is on, the cheap attempt is only even tried
    /// for RAW files (confirmed via `UTType.rawImage`, not a file
    /// extension guess): a plain JPEG/HEIC's embedded preview is reliably
    /// far too small for the loupe, so trying it first would just mean
    /// decoding the file twice — once wastefully, once for real. RAW is
    /// the opposite case: its embedded preview is typically large enough
    /// on its own, which is the whole reason to try it first.
    static func decodeImage(_ url: URL, maxPixelSize: CGFloat, verifyResolution: Bool = true) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let baseOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        let isRAW = (CGImageSourceGetType(source) as String?)
            .flatMap(UTType.init)
            .map { $0.conforms(to: .rawImage) } ?? false

        if !verifyResolution || isRAW {
            var ifAbsentOptions = baseOptions
            ifAbsentOptions[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            let cheap = CGImageSourceCreateThumbnailAtIndex(source, 0, ifAbsentOptions as CFDictionary)

            if !verifyResolution {
                return cheap
            }
            if let cheap, CGFloat(max(cheap.width, cheap.height)) >= maxPixelSize {
                return cheap
            }
        }

        var alwaysOptions = baseOptions
        alwaysOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, alwaysOptions as CFDictionary)
    }
}
