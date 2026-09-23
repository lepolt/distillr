import Testing
@testable import Core

struct ThumbnailLoaderTests {
    @Test func extractsRAWEmbeddedPreviewAtFullResolution() throws {
        let image = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3742.NEF"), maxPixelSize: 8000))
        // Sensor active area vs. the embedded preview's own output crop
        // legitimately differ slightly; just confirm it's a real, full-size
        // image rather than a small thumbnail.
        #expect(image.width >= 6000)
        #expect(image.height >= 4000)
    }

    @Test func rotatesPortraitJPEGsUprightBothDirections() throws {
        let landscape = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3676.JPG"), maxPixelSize: 8000))
        #expect(landscape.width > landscape.height)

        let rotated90 = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3751.JPG"), maxPixelSize: 8000))
        #expect(rotated90.width < rotated90.height, "orientation 6 (Rotate 90 CW) should come out portrait")

        let rotated270 = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3766.JPG"), maxPixelSize: 8000))
        #expect(rotated270.width < rotated270.height, "orientation 8 (Rotate 270 CW) should come out portrait")
    }

    @Test func decodesRAWFiles() throws {
        let image = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3742.NEF"), maxPixelSize: 8000))
        #expect(image.width >= 6000)
        #expect(image.height >= 4000)
    }

    /// Regression test: most plain JPEGs carry nothing but a tiny ~160x120
    /// EXIF preview meant for a camera's own LCD. Preferring an embedded
    /// thumbnail whenever one exists — without checking whether it's
    /// actually big enough — silently returned that tiny preview instead of
    /// a real downsample of the 6048x4032 source, which is exactly what
    /// made every photo in Review look low-resolution, not just RAW files.
    @Test func decodesJPEGsAtRequestedResolutionNotTheirTinyEmbeddedPreview() throws {
        let image = try #require(ThumbnailLoader.decodeImage(examplePath("DSC_3676.JPG"), maxPixelSize: 4000))
        #expect(max(image.width, image.height) >= 4000)
    }
}
