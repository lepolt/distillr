import Foundation

/// Folder walking, with RAW+JPEG pairing. Works on any path the OS
/// resolves, including a mounted SD card/camera volume — a removable
/// volume looks like any other folder to `FileManager`, so no
/// special-casing is needed. Scanning is flat (not recursive), so the
/// caller needs to point at the folder that directly contains the photos.
enum PhotoScanner {
    /// Lists photos directly inside `root` (non-recursive), pairing
    /// RAW+JPEG files that share a base filename, sorted by the primary
    /// path.
    static func scanFolder(_ root: URL) throws -> [PhotoSource] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var byStem: [String: [URL]] = [:]
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            guard isJPEGExtension(url) || isRAWExtension(url) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            byStem[stem, default: []].append(url)
        }

        var sources: [PhotoSource] = byStem.values.compactMap { group in
            var paths = group.sorted { $0.path < $1.path }
            guard let jpegIndex = paths.firstIndex(where: isJPEGExtension) else {
                guard let raw = paths.first(where: isRAWExtension) else { return nil }
                return PhotoSource(primary: raw, sidecar: nil)
            }
            let jpeg = paths.remove(at: jpegIndex)
            let raw = paths.first(where: isRAWExtension)
            return PhotoSource(primary: jpeg, sidecar: raw)
        }

        sources.sort { $0.primary.path < $1.primary.path }
        return sources
    }
}
