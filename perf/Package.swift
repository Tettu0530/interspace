// swift-tools-version:5.9
import PackageDescription

// The benchmark build of Interspace. Its sources are links to the sources of the app, all but `main.swift`,
// so it measures the code of the app as it is. It never posts a space switch and shows nothing on screen.
let package = Package(
    name: "InterspacePerf",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CDockSwipe", path: "Sources/CDockSwipe"),
        .executableTarget(name: "InterspacePerf", dependencies: ["CDockSwipe"], path: "Sources/InterspacePerf"),
    ]
)
