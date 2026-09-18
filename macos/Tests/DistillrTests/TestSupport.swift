import Foundation
@testable import Distillr

/// Real camera-file fixtures live one level up from `macos/`, shared with
/// the original Rust app's test suite (see `crates/*/src/lib.rs`). Never
/// mutate this directory directly — copy to a disposable temp directory
/// first for any test that performs a destructive operation (trash/copy).
func examplesDir() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // this file
        .deletingLastPathComponent() // DistillrTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .appendingPathComponent("examples")
}

func examplePath(_ name: String) -> URL {
    examplesDir().appendingPathComponent(name)
}

/// Copies the named real fixture files into a fresh disposable temp
/// directory, for tests that need to mutate or delete files.
func disposableCopyOfExamples(_ names: [String], label: String = #function) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("distillr-test-\(label)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in names {
        try! FileManager.default.copyItem(at: examplePath(name), to: dir.appendingPathComponent(name))
    }
    return dir
}

/// Waits for the background thumbnail decode `AppModel.loadFolder` kicks
/// off to finish, polling `model.thumbnails.count`. Generous timeout since
/// `swift test` may run other work concurrently.
@MainActor
func waitForThumbnails(_ model: AppModel, total: Int, timeout: TimeInterval = 60) async {
    let deadline = Date().addingTimeInterval(timeout)
    while model.thumbnails.count < total && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Waits for `AppModel.loadLoupeImage`'s background decode to land in
/// `loupeCache` for `path`.
@MainActor
func waitForLoupeImage(_ model: AppModel, path: URL, timeout: TimeInterval = 30) async {
    let deadline = Date().addingTimeInterval(timeout)
    while model.loupeCache[path] == nil && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
