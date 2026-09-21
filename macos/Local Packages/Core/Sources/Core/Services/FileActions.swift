import Foundation

/// Finalize actions: trashing rejected photos and copying keepers to a
/// destination folder.
enum FileActions {
    struct TrashReport {
        var trashed: [URL] = []
        var failed: [(URL, String)] = []
        var isSuccess: Bool { failed.isEmpty }
    }

    struct CopyReport {
        var copied: [URL] = []
        /// A file with the same name already existed at the destination,
        /// so it was left alone rather than silently overwritten.
        var skippedExisting: [URL] = []
        var failed: [(URL, String)] = []
        var isSuccess: Bool { failed.isEmpty }
    }

    /// Moves each path to the OS trash — never a hard delete. Keeps going
    /// past individual failures (a file already gone, permissions, etc.)
    /// instead of aborting the whole batch on the first error.
    static func trashPaths(_ paths: [URL]) -> TrashReport {
        var report = TrashReport()
        for path in paths {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: path, resultingItemURL: &trashedURL)
                report.trashed.append(path)
            } catch {
                report.failed.append((path, error.localizedDescription))
            }
        }
        return report
    }

    /// Copies each path into `destination` (created if it doesn't exist
    /// yet), keeping the original file name. Originals are left in place —
    /// this is a copy, not a move. A name already present at the
    /// destination is skipped rather than overwritten, so re-running
    /// Finalize after a partial copy (or across sessions into the same
    /// destination) never clobbers a file.
    static func copyPaths(_ paths: [URL], to destination: URL) -> CopyReport {
        var report = CopyReport()

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            for path in paths {
                report.failed.append((path, "could not create destination: \(error.localizedDescription)"))
            }
            return report
        }

        for path in paths {
            let destPath = destination.appendingPathComponent(path.lastPathComponent)
            if FileManager.default.fileExists(atPath: destPath.path) {
                report.skippedExisting.append(path)
                continue
            }
            do {
                try FileManager.default.copyItem(at: path, to: destPath)
                report.copied.append(path)
            } catch {
                report.failed.append((path, error.localizedDescription))
            }
        }

        return report
    }
}
