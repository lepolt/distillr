import Testing
@testable import Core

struct PhotoDetailsReaderTests {
    @Test func readsFocusAreaFromRAWMatchingExiftoolsOwnOutput() throws {
        // Confirmed against the real file this session: a standalone probe
        // matched `exiftool -AFAreaXPosition/YPosition/Width/Height`
        // exactly (X=3023 Y=2016 W=293 H=316), and AFImageWidth/Height
        // (6048x4032) match this photo's own full resolution, so an
        // orientation-1 (unrotated) shot needs no rotation transform.
        // AFAreaXPosition/YPosition are the rectangle's CENTER, not its
        // top-left corner — confirmed by rendering a real off-center AF
        // point against its subject, so the expected values here are
        // exiftool's raw X/Y minus half the width/height.
        let details = PhotoDetailsReader.readDetails(examplePath("DSC_3742.NEF"))
        let area = try #require(details.focusArea)
        #expect(area.x == 2876.5)
        #expect(area.y == 1858)
        #expect(area.width == 293)
        #expect(area.height == 316)
        #expect(area.referenceWidth == 6048)
        #expect(area.referenceHeight == 4032)
    }

    @Test func readsFocusAreaFromJPEGMatchingTheRAWPair() throws {
        // Same underlying MakerNote data, different container: JPEG wraps
        // the identical TIFF/MakerNote structure inside an APP1 "Exif\0\0"
        // segment instead of starting at file offset 0. This confirms
        // `tiffBase` correctly locates it in both.
        let details = PhotoDetailsReader.readDetails(examplePath("DSC_3676.JPG"))
        let area = try #require(details.focusArea)
        #expect(area.x == 2876.5)
        #expect(area.y == 1858)
        #expect(area.width == 293)
        #expect(area.height == 316)
    }

    @Test func rotatesTheFocusAreaForOrientation6() throws {
        // Real orientation-6 ("Rotate 90 CW") file. Raw MakerNote position
        // is the same sensor-relative (3023, 2016, 293, 316) as every
        // other sample here — confirmed by checking it directly with
        // exiftool — so this only passes if the orientation transform is
        // actually being applied, not just passing the raw values through.
        // Expected values hand-derived this session via corner-by-corner
        // rotation of the source rect, cross-checked by confirming the
        // near-center source point still maps to the near-center of the
        // rotated (4032x6048) frame.
        let details = PhotoDetailsReader.readDetails(examplePath("DSC_3751.JPG"))
        let area = try #require(details.focusArea)
        #expect(area.x == 1858)
        #expect(area.y == 2876.5)
        #expect(area.width == 316)
        #expect(area.height == 293)
        #expect(area.referenceWidth == 4032)
        #expect(area.referenceHeight == 6048)
    }

    @Test func rotatesTheFocusAreaForOrientation8() throws {
        // Real orientation-8 ("Rotate 270 CW") file — same derivation
        // discipline as orientation 6 above, opposite rotation direction.
        let details = PhotoDetailsReader.readDetails(examplePath("DSC_3766.JPG"))
        let area = try #require(details.focusArea)
        #expect(area.x == 1858)
        #expect(area.y == 2878.5)
        #expect(area.width == 316)
        #expect(area.height == 293)
        #expect(area.referenceWidth == 4032)
        #expect(area.referenceHeight == 6048)
    }

    @Test func readsStandardShootingDetails() {
        let details = PhotoDetailsReader.readDetails(examplePath("DSC_3742.NEF"))
        #expect(details.cameraModel == "NIKON Z6_3")
        #expect(details.lensModel == "NIKKOR Z 70-200mm f/2.8 VR S II")
        #expect(details.focalLength == 200)
        #expect(details.aperture == 4)
        #expect(details.shutterSpeed == 0.005)
        #expect(details.iso == 14400)
        #expect(details.pixelWidth == 6048)
        #expect(details.pixelHeight == 4032)
        #expect(details.megapixelsText == "24 MP")
        #expect(details.format == "NEF")
        #expect((details.fileSize ?? 0) > 0)
    }
}
