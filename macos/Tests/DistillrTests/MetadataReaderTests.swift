import Foundation
import Testing
@testable import Distillr

struct MetadataReaderTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func readsNikonJPEGMetadata() throws {
        let meta = try MetadataReader.readMetadata(examplePath("DSC_3676.JPG"))
        #expect(meta.cameraModel == "NIKON Z6_3")
        #expect(meta.width == 6048)
        #expect(meta.height == 4032)
        let components = utc.dateComponents([.hour, .minute, .second], from: meta.captureTime)
        #expect(components.hour == 9)
        #expect(components.minute == 16)
        #expect(components.second == 14)
    }

    @Test func parsesSubsecondPrecisionForBurstOrdering() throws {
        let a = try MetadataReader.readMetadata(examplePath("DSC_3676.JPG"))
        let b = try MetadataReader.readMetadata(examplePath("DSC_3677.JPG"))
        #expect(b.captureTime > a.captureTime)
        let gapMs = b.captureTime.timeIntervalSince(a.captureTime) * 1000
        // Nikon Z6III high-speed burst is well under half a second between frames.
        #expect(gapMs > 0 && gapMs < 500)
    }

    @Test func parsesSubsecStringVariants() {
        #expect(MetadataReader.parseSubsecondFraction("08") == 0.08)
        #expect(MetadataReader.parseSubsecondFraction("8") == 0.8)
        #expect(MetadataReader.parseSubsecondFraction("") == 0)
        #expect(MetadataReader.parseSubsecondFraction(nil) == 0)
    }

    @Test func readsNikonNEFMetadataMatchingItsPairedJPEG() throws {
        let jpeg = try MetadataReader.readMetadata(examplePath("DSC_3742.JPG"))
        let raw = try MetadataReader.readMetadata(examplePath("DSC_3742.NEF"))
        #expect(raw.captureTime == jpeg.captureTime)
        #expect(raw.cameraModel == "NIKON Z6_3")
    }

    @Test func isRAWExtensionRecognizesNEFButNotJPEG() {
        #expect(isRAWExtension(URL(fileURLWithPath: "foo.NEF")))
        #expect(isRAWExtension(URL(fileURLWithPath: "foo.nef")))
        #expect(!isRAWExtension(URL(fileURLWithPath: "foo.jpg")))
    }

    @Test func readsOrientationForLandscapeAndBothPortraitDirections() throws {
        let landscape = try MetadataReader.readMetadata(examplePath("DSC_3676.JPG"))
        #expect(landscape.orientation == 1)

        let rotated90 = try MetadataReader.readMetadata(examplePath("DSC_3751.JPG"))
        #expect(rotated90.orientation == 6)

        let rotated270 = try MetadataReader.readMetadata(examplePath("DSC_3766.JPG"))
        #expect(rotated270.orientation == 8)
    }
}
