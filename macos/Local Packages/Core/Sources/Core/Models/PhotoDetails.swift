import Foundation

/// The camera's autofocus rectangle for a photo, already corrected for EXIF
/// orientation so it's directly usable against the *displayed* (rotated)
/// image — the raw MakerNote data is relative to the sensor's native,
/// unrotated pixel grid, not what's actually shown.
struct FocusArea: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// The pixel space `x`/`y`/`width`/`height` are defined in — matches
    /// the displayed image's own dimensions (post-rotation), so a caller
    /// only ever needs to divide by these, never worry about orientation
    /// itself.
    var referenceWidth: Double
    var referenceHeight: Double
}

/// Shooting details for display in Review — deliberately separate from
/// `PhotoMetadata`, which is read synchronously for *every* photo at
/// folder-load time to support burst grouping. This is read lazily, only
/// for whichever photo is actually being reviewed, the same way
/// `AppModel.loupeCache` is lazy while `thumbnails` isn't.
struct PhotoDetails: Equatable {
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var focalLength35mm: Double?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var exposureBias: Double?
    var whiteBalance: String?
    var focusArea: FocusArea?

    var pixelWidth: Int?
    var pixelHeight: Int?
    var fileSize: Int64?
    var format: String?

    /// "24 MP", rounded to the nearest whole megapixel like Photos does.
    var megapixelsText: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(Int((Double(pixelWidth * pixelHeight) / 1_000_000).rounded())) MP"
    }

    var dimensionsText: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var fileSizeText: String? {
        fileSize.map { $0.formatted(.byteCount(style: .file)) }
    }

    /// The bottom row of the info card, in Photos' order, each skipped when
    /// absent.
    var exposureItems: [String] {
        var items: [String] = []
        if let iso { items.append("ISO \(iso)") }
        if let focalLength { items.append("\(Int(focalLength.rounded())) mm") }
        if let exposureBias {
            items.append("\(exposureBias.formatted(.number.precision(.fractionLength(0...1)))) ev")
        }
        if let aperture { items.append("ƒ\(aperture.formatted(.number.precision(.fractionLength(0...1))))") }
        if let shutterSpeed { items.append(Self.formatShutterSpeed(shutterSpeed)) }
        return items
    }

    private static func formatShutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        if seconds >= 1 {
            return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
        }
        return "1/\(Int((1 / seconds).rounded())) s"
    }
}
