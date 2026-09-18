// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Distillr",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Distillr",
            path: "Sources/Distillr",
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "DistillrTests",
            dependencies: ["Distillr"],
            path: "Tests/DistillrTests"
        ),
    ]
)
