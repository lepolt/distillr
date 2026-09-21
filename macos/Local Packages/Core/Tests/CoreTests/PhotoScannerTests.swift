import Foundation
import Testing
@testable import Core

struct PhotoScannerTests {
    @Test func findsAllExamplePhotosSortedByPrimary() throws {
        let found = try PhotoScanner.scanFolder(examplesDir())
        // 93 standalone JPEGs (66 original + 15 + 10 portrait + DSC_3900/3901)
        // + 9 RAW+JPEG pairs.
        #expect(found.count == 102)
        for i in 1..<found.count {
            #expect(found[i - 1].primary.path < found[i].primary.path)
        }
        #expect(found[0].primary.lastPathComponent == "DSC_3676.JPG")
    }

    @Test func pairsRAWAndJPEGSharingABaseFilename() throws {
        let found = try PhotoScanner.scanFolder(examplesDir())
        let paired = try #require(found.first { $0.primary.lastPathComponent == "DSC_3742.JPG" })
        #expect(paired.sidecar?.lastPathComponent == "DSC_3742.NEF")
    }

    @Test func standaloneJPEGHasNoSidecar() throws {
        let found = try PhotoScanner.scanFolder(examplesDir())
        let solo = try #require(found.first { $0.primary.lastPathComponent == "DSC_3676.JPG" })
        #expect(solo.sidecar == nil)
    }

    @Test func rawOnlyFileBecomesItsOwnPrimary() throws {
        let dir = tempDir("raw-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("fake-raw".utf8).write(to: dir.appendingPathComponent("IMG_0001.NEF"))

        let found = try PhotoScanner.scanFolder(dir)

        #expect(found.count == 1)
        #expect(found[0].primary.lastPathComponent == "IMG_0001.NEF")
        #expect(found[0].sidecar == nil)
    }

    @Test func ignoresNonPhotoFiles() throws {
        let dir = tempDir("ignore-others")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("fake".utf8).write(to: dir.appendingPathComponent("photo.JPG"))

        let found = try PhotoScanner.scanFolder(dir)
        #expect(found.count == 1)
    }

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distillr-scan-test-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
