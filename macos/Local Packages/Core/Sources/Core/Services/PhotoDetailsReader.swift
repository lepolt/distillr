import Foundation
import ImageIO

/// Reads shooting details for display in Review, including — for Nikon
/// Expeed 7 cameras (Z6III/Zf/Z8/Z9/Z50II) specifically — the camera's own
/// autofocus rectangle. That part isn't standard EXIF: it's proprietary
/// Nikon MakerNote data that ImageIO doesn't expose at all (confirmed by
/// dumping every property dictionary ImageIO returns for a real NEF and
/// JPEG — nothing). Verified this session against real files by writing a
/// standalone parser and matching `exiftool`'s own output exactly, for
/// both NEF and JPEG containers.
enum PhotoDetailsReader {
    static func readDetails(_ url: URL) -> PhotoDetails {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return PhotoDetails()
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let makerNikon = props[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any]
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1

        var details = PhotoDetails(
            cameraModel: (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            focalLength: exif?[kCGImagePropertyExifFocalLength] as? Double,
            focalLength35mm: (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue,
            aperture: (exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
            shutterSpeed: exif?[kCGImagePropertyExifExposureTime] as? Double,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue,
            exposureBias: exif?[kCGImagePropertyExifExposureBiasValue] as? Double,
            whiteBalance: makerNikon?[kCGImagePropertyMakerNikonWhiteBalanceMode] as? String,
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int,
            fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
            format: formatLabel(url)
        )

        if let subjectArea = subjectAreaRect(exif) {
            details.focusArea = subjectArea
        } else if (tiff?[kCGImagePropertyTIFFMake] as? String)?.uppercased().contains("NIKON") == true,
                  let data = try? Data(contentsOf: url) {
            details.focusArea = NikonFocusAreaParser.parse(data, orientation: orientation)
        }

        return details
    }

    /// The *standard* EXIF `SubjectArea` tag (0xA214) — a 2 (center point,
    /// no area), 3 (circle: center + diameter), or 4 (rect: x,y,w,h) value
    /// array. Checked before any Nikon-specific parsing: free via ImageIO
    /// for any camera/phone that writes it, no custom parsing needed. This
    /// Nikon doesn't write it (checked all 9 sample NEFs), but it costs
    /// nothing to prefer it when present.
    private static func formatLabel(_ url: URL) -> String? {
        let ext = url.pathExtension.uppercased()
        if ext.isEmpty { return nil }
        return ext == "JPG" ? "JPEG" : ext
    }

    private static func subjectAreaRect(_ exif: [CFString: Any]?) -> FocusArea? {
        guard let values = (exif?[kCGImagePropertyExifSubjectArea] as? [NSNumber])?.map(\.doubleValue) else {
            return nil
        }
        // A 2-value center point carries no size, so there's nothing to
        // draw a rectangle from.
        switch values.count {
        case 3:
            let (x, y, diameter) = (values[0], values[1], values[2])
            return FocusArea(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter, referenceWidth: 0, referenceHeight: 0)
        case 4:
            return FocusArea(x: values[0], y: values[1], width: values[2], height: values[3], referenceWidth: 0, referenceHeight: 0)
        default:
            return nil
        }
    }
}

/// Nikon MakerNote AF-area parsing, scoped to the Expeed 7 processor
/// generation (`AFInfo2` version `040x`) — the Z6III this app was built
/// against, plus the Zf/Z8/Z9/Z50II, which share the same table per
/// ExifTool's own Nikon.pm. Older Nikon generations and other
/// manufacturers are out of scope: the version-string gate below returns
/// `nil` rather than guess at offsets that don't apply.
private enum NikonFocusAreaParser {
    static func parse(_ data: Data, orientation: Int) -> FocusArea? {
        guard let base = tiffBase(data) else { return nil }
        let r = ByteReader(data: data, base: base)
        guard let littleEndian = r.byteOrder(at: base) else { return nil }
        let r2 = ByteReader(data: data, base: base, littleEndian: littleEndian)

        guard let ifd0Offset = r2.u32(base + 4).map({ base + Int($0) }),
              let ifd0 = ifdEntries(r2, ifdOffset: ifd0Offset),
              let exifEntry = ifd0.first(where: { $0.tag == 0x8769 })
        else { return nil }

        let exifIFDOffset = base + Int(exifEntry.valueOrOffset)
        guard let exifIFD = ifdEntries(r2, ifdOffset: exifIFDOffset),
              let makerEntry = exifIFD.first(where: { $0.tag == 0x927c })
        else { return nil }

        let makerNoteOffset = base + Int(makerEntry.valueOrOffset)
        guard data.count >= makerNoteOffset + 10,
              String(bytes: data[makerNoteOffset..<(makerNoteOffset + 5)], encoding: .ascii) == "Nikon"
        else { return nil }

        // Nikon's MakerNote is a TIFF structure nested inside the outer
        // one, starting 10 bytes into the MakerNote block, with its own
        // byte-order mark and all inner offsets relative to this point —
        // not the outer TIFF's base, and not the file start.
        let nestedBase = makerNoteOffset + 10
        guard let nestedLittleEndian = r2.byteOrder(at: nestedBase) else { return nil }
        let nr = ByteReader(data: data, base: nestedBase, littleEndian: nestedLittleEndian)

        guard let nestedIFD0Offset = nr.u32(nestedBase + 4).map({ nestedBase + Int($0) }),
              let nikonIFD = ifdEntries(nr, ifdOffset: nestedIFD0Offset),
              let afInfoEntry = nikonIFD.first(where: { $0.tag == 0x00b7 })
        else { return nil }

        let afInfoOffset = nestedBase + Int(afInfoEntry.valueOrOffset)
        guard data.count >= afInfoOffset + 0x4a else { return nil }

        let version = String(bytes: data[afInfoOffset..<(afInfoOffset + 4)], encoding: .ascii) ?? ""
        guard version.hasPrefix("040") else { return nil }

        let coordinatesAvailable = data[afInfoOffset + 7]
        guard coordinatesAvailable == 1 else { return nil }

        guard let imageWidth = nr.u16(afInfoOffset + 0x3e),
              let imageHeight = nr.u16(afInfoOffset + 0x40),
              let x = nr.u16(afInfoOffset + 0x42),
              let y = nr.u16(afInfoOffset + 0x44),
              let width = nr.u16(afInfoOffset + 0x46),
              let height = nr.u16(afInfoOffset + 0x48)
        else { return nil }

        // AFAreaXPosition/AFAreaYPosition are the rectangle's CENTER, not
        // its top-left corner — confirmed empirically this session by
        // rendering a real off-center AF point (a soccer player's face)
        // under both interpretations: only the center interpretation
        // lands the box on the subject. `FocusArea` stores top-left
        // throughout, so convert here.
        return applyOrientation(
            FocusArea(
                x: Double(x) - Double(width) / 2, y: Double(y) - Double(height) / 2,
                width: Double(width), height: Double(height),
                referenceWidth: Double(imageWidth), referenceHeight: Double(imageHeight)
            ),
            orientation: orientation
        )
    }

    /// The AF area above is relative to the sensor's native, unrotated
    /// pixel grid — confirmed this session by checking real orientation-6
    /// and orientation-8 files, where the raw AF position stayed constant
    /// regardless of orientation. `ThumbnailLoader` already auto-rotates
    /// the decoded image via `kCGImageSourceCreateThumbnailWithTransform`,
    /// so without this, the rectangle would be wrong for every rotated
    /// (portrait) photo. Standard 2D rectangle rotation; orientations 2/4/5/7
    /// (the mirrored variants) aren't handled since Nikon doesn't write them.
    private static func applyOrientation(_ area: FocusArea, orientation: Int) -> FocusArea {
        let w = area.referenceWidth, h = area.referenceHeight
        switch orientation {
        case 3: // 180°
            return FocusArea(
                x: w - area.x - area.width, y: h - area.y - area.height,
                width: area.width, height: area.height,
                referenceWidth: w, referenceHeight: h
            )
        case 6: // 90° CW
            return FocusArea(
                x: h - area.y - area.height, y: area.x,
                width: area.height, height: area.width,
                referenceWidth: h, referenceHeight: w
            )
        case 8: // 90° CCW
            return FocusArea(
                x: area.y, y: w - area.x - area.width,
                width: area.height, height: area.width,
                referenceWidth: h, referenceHeight: w
            )
        default: // 1, or anything unrecognized — leave unrotated
            return area
        }
    }

    /// Where the TIFF/IFD structure actually starts: file offset 0 for a
    /// bare TIFF-based RAW, or right after the `Exif\0\0` marker inside a
    /// JPEG's `APP1` segment. Scans markers rather than assuming a fixed
    /// offset, since a JFIF `APP0` segment can precede `APP1`.
    private static func tiffBase(_ data: Data) -> Int? {
        guard data.count > 4 else { return nil }
        guard data[0] == 0xFF, data[1] == 0xD8 else { return 0 } // not a JPEG
        var offset = 2
        while offset + 4 <= data.count, data[offset] == 0xFF {
            let type = data[offset + 1]
            let segmentLength = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if type == 0xE1, offset + 10 <= data.count,
               String(bytes: data[(offset + 4)..<(offset + 10)], encoding: .ascii) == "Exif\0\0" {
                return offset + 10
            }
            offset += 2 + segmentLength
        }
        return nil
    }
}

/// Minimal big/little-endian TIFF field reader, bounds-checked throughout
/// since this walks arbitrary file bytes rather than a format ImageIO has
/// already validated.
private struct ByteReader {
    let data: Data
    let base: Int
    var littleEndian: Bool = true

    /// Reads the 2-byte TIFF byte-order mark ("II"/"MM") at `offset`.
    func byteOrder(at offset: Int) -> Bool? {
        guard data.count >= offset + 2 else { return nil }
        switch String(bytes: data[offset..<(offset + 2)], encoding: .ascii) {
        case "II": return true
        case "MM": return false
        default: return nil
        }
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, data.count >= offset + 2 else { return nil }
        let b0 = UInt16(data[offset]), b1 = UInt16(data[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        let b0 = UInt32(data[offset]), b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2]), b3 = UInt32(data[offset + 3])
        return littleEndian
            ? (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }
}

private struct IFDEntry {
    let tag: UInt16
    let valueOrOffset: UInt32
}

/// Reads one IFD's entries: a 2-byte count, then 12 bytes each (tag, type,
/// count, value-or-offset). Only `valueOrOffset` is needed here — every
/// tag this parser cares about (sub-IFD pointers, the AFInfo2 offset) uses
/// it as a plain offset, never an inline value.
private func ifdEntries(_ r: ByteReader, ifdOffset: Int) -> [IFDEntry]? {
    guard let count = r.u16(ifdOffset) else { return nil }
    var entries: [IFDEntry] = []
    for i in 0..<Int(count) {
        let entryOffset = ifdOffset + 2 + i * 12
        guard let tag = r.u16(entryOffset), let valOff = r.u32(entryOffset + 8) else { return nil }
        entries.append(IFDEntry(tag: tag, valueOrOffset: valOff))
    }
    return entries
}
