import AppKit

@MainActor
enum FolderPicker {
    /// Native folder picker — works for a mounted SD card/camera volume the
    /// same as any other folder, since it's just an `NSOpenPanel`.
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Destination"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Resolves a Finder drag-and-drop payload to a folder, for the
    /// "or drop folder here" tile and the compact header's own drop target.
    /// A dropped file (rather than a folder) falls back to its containing
    /// folder, so dropping one photo from a shoot still does something
    /// useful. `completion` runs on the main actor.
    static func resolveDroppedFolder(_ providers: [NSItemProvider], completion: @escaping @MainActor @Sendable (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                completion(isDirectory.boolValue ? url : url.deletingLastPathComponent())
            }
        }
        return true
    }
}
