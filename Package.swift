// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Interspace",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CDockSwipe",
            path: "Sources/CDockSwipe"
        ),
        .executableTarget(
            name: "Interspace",
            dependencies: ["CDockSwipe"],
            path: "Sources/Interspace"
        ),
    ]
)
