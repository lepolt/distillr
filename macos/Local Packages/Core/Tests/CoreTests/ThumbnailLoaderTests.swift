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
}
