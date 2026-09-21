// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v26)],
    products: [
        // Explicit — without this, the Distillr app target's dependency
        // on "Core" fails to resolve at build time ("Missing package
        // product 'Core'") even though the package itself resolves fine,
        // since SPM doesn't implicitly vend a product when `products` is
        // omitted.
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        // A library, not an executable: this package is now consumed as a
        // local Swift package dependency of the Distillr Xcode app target
        // (Distillr/Distillr.xcodeproj), which supplies the real @main
        // entry point and owns app-lifecycle concerns (window activation,
        // icon, sizing). Core's public surface is just `AppModel` and
        // `ContentView`.
        .target(name: "Core"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
    ]
)
