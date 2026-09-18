import Foundation
import Testing
@testable import Distillr

struct FileActionsTests {
    private func tempFile(_ name: String, _ contents: String, label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distillr-actions-test-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name)
        try! Data(contents.utf8).write(to: path)
        return path
    }

    @Test func trashesExistingFilesAndReportsThem() {
        let a = tempFile("a.jpg", "a", label: "trash-basic")
        let b = tempFile("b.jpg", "b", label: "trash-basic")

        let report = FileActions.trashPaths([a, b])

        #expect(report.isSuccess)
        #expect(report.trashed == [a, b])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func missingFileIsReportedAsAFailureWithoutAbortingTheBatch() {
        let real = tempFile("real.jpg", "x", label: "trash-missing")
        let missing = real.deletingLastPathComponent().appendingPathComponent("does-not-exist.jpg")

        let report = FileActions.trashPaths([missing, real])

        #expect(!report.isSuccess)
        #expect(report.failed.count == 1)
        #expect(report.failed[0].0 == missing)
        #expect(report.trashed == [real])
        #expect(!FileManager.default.fileExists(atPath: real.path))
    }

    private func tempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distillr-actions-test-\(label)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func copiesFilesToANewDestinationLeavingOriginalsInPlace() throws {
        let src = tempDir("copy-src")
        let dest = tempDir("copy-dest")
        try FileManager.default.removeItem(at: dest) // copyPaths should create it

        let a = src.appendingPathComponent("a.jpg")
        let b = src.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let report = FileActions.copyPaths([a, b], to: dest)

        #expect(report.isSuccess)
        #expect(report.copied == [a, b])
        #expect(FileManager.default.fileExists(atPath: a.path), "original should be untouched by a copy")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.jpg").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("b.jpg").path))
        #expect(try Data(contentsOf: dest.appendingPathComponent("a.jpg")) == Data("a".utf8))
    }

    @Test func skipsRatherThanOverwritesAnExistingDestinationFile() throws {
        let src = tempDir("copy-src-existing")
        let dest = tempDir("copy-dest-existing")

        let a = src.appendingPathComponent("a.jpg")
        try Data("new-content".utf8).write(to: a)
        try Data("already-there".utf8).write(to: dest.appendingPathComponent("a.jpg"))

        let report = FileActions.copyPaths([a], to: dest)

        #expect(report.copied.isEmpty)
        #expect(report.skippedExisting == [a])
        #expect(try Data(contentsOf: dest.appendingPathComponent("a.jpg")) == Data("already-there".utf8))
    }
}
