import Foundation
import ImageIO

/// EXIF metadata reading via ImageIO — one code path for both JPEG and RAW
/// (NEF verified against real Nikon Z6III files), unlike the original Rust
/// app which needed separate JPEG-EXIF and RAW-decoder readers.
enum MetadataReader {
    static func readMetadata(_ url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw MetadataError.cannotOpenImageSource
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        let dateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let subsecTimeOriginal = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String
        let captureTime = try parseCaptureTime(
            dateTimeOriginal: dateTimeOriginal,
            subsecTimeOriginal: subsecTimeOriginal
        )

        let cameraModel = (tiff?[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty

        return PhotoMetadata(
            captureTime: captureTime,
            cameraModel: cameraModel,
            width: props[kCGImagePropertyPixelWidth] as? Int,
            height: props[kCGImagePropertyPixelHeight] as? Int,
            orientation: props[kCGImagePropertyOrientation] as? Int
        )
    }

    /// Parses the EXIF-style `DateTimeOriginal` ("YYYY:MM:DD HH:MM:SS") plus
    /// an optional subsecond digit string. The subsecond string is a
    /// fraction, not a fixed unit — "08" means 0.08s, "8" means 0.8s —
    /// there's no fixed digit count across cameras, so it's right-padded to
    /// nanosecond width before converting.
    static func parseCaptureTime(dateTimeOriginal: String?, subsecTimeOriginal: String?) throws -> Date {
        guard let raw = dateTimeOriginal else { throw MetadataError.missingCaptureTime }

        let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 6 else { throw MetadataError.invalidCaptureTime(raw) }

        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else {
            throw MetadataError.invalidCaptureTime(raw)
        }

        return date.addingTimeInterval(parseSubsecondFraction(subsecTimeOriginal))
    }

    static func parseSubsecondFraction(_ raw: String?) -> TimeInterval {
        guard let raw else { return 0 }
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return 0 }
        let padded = String(digits.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
        guard let nanos = Int(padded) else { return 0 }
        return Double(nanos) / 1_000_000_000.0
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
