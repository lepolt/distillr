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

    /// Checks that `destination` is actually writable — creating it if it
    /// doesn't exist yet, then writing and removing a small probe file —
    /// rather than just inspecting permission bits: `isWritableFile(atPath:)`
    /// doesn't account for App Sandbox's file-access entitlements, which
    /// silently deny writes to a folder that otherwise looks normally
    /// permissioned. Returns a human-readable reason it isn't writable, or
    /// `nil` if it's fine. Meant to be called before Finalize actually
    /// copies anything, so a permission problem surfaces as one clear
    /// message up front instead of a wall of per-photo copy failures.
    static func writeAccessError(for destination: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return "Can't create \(destination.lastPathComponent): \(error.localizedDescription)"
        }

        let probe = destination.appendingPathComponent(".distillr-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
        } catch {
            return "Distillr doesn't have permission to write to \(destination.path)."
        }
        try? FileManager.default.removeItem(at: probe)
        return nil
    }
}
