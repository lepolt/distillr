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

    /// A single compact line for Review's header — camera, lens, focal
    /// length, aperture, shutter, ISO, white balance, each skipped when
    /// absent rather than showing a placeholder.
    var summaryLine: String {
        var parts: [String] = []
        if let cameraModel { parts.append(cameraModel) }
        if let lensModel { parts.append(lensModel) }
        if let focalLength { parts.append("\(Int(focalLength))mm") }
        if let aperture { parts.append("f/\(aperture.formatted(.number.precision(.fractionLength(0...1))))") }
        if let shutterSpeed { parts.append(Self.formatShutterSpeed(shutterSpeed)) }
        if let iso { parts.append("ISO \(iso)") }
        if let whiteBalance { parts.append(whiteBalance) }
        return parts.joined(separator: " · ")
    }

    private static func formatShutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        if seconds >= 1 {
            return "\(seconds.formatted(.number.precision(.fractionLength(0...1))))s"
        }
        return "1/\(Int((1 / seconds).rounded()))s"
    }
}
