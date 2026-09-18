import AppKit
import SwiftUI

@main
struct DistillrApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 650)
                .onAppear {
                    // A bare executable launched via `swift run` from
                    // Terminal doesn't automatically become the OS-level
                    // active/foreground app the way double-clicking a
                    // built .app (or Xcode's Run) does — the window can
                    // look frontmost while Terminal is still what actually
                    // receives keystrokes. Force activation explicitly so
                    // keyboard input goes to this app regardless of how
                    // it was launched.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)

                    // Running as a bare SPM executable (not a packaged
                    // .app), so there's no Info.plist/Assets.xcassets for
                    // the system to read a custom icon from — set the Dock
                    // tile image directly instead. This is separate from
                    // the window's own icon-in-titlebar, which macOS
                    // always derives from the running process regardless.
                    if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: iconURL) {
                        NSApp.applicationIconImage = icon
                    }
                }
        }
    }
}
