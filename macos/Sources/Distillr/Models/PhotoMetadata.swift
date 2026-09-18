import Foundation

struct PhotoMetadata: Equatable {
    let captureTime: Date
    let cameraModel: String?
    let width: Int?
    let height: Int?
    /// Standard EXIF orientation (1-8). Informational only — display decode
    /// doesn't need to apply this manually, since ImageIO's thumbnail
    /// generation (`kCGImageSourceCreateThumbnailWithTransform`) already
    /// does it from the same tag.
    let orientation: Int?
}

enum MetadataError: Error, Equatable {
    case cannotOpenImageSource
    case missingCaptureTime
    case invalidCaptureTime(String)
}
