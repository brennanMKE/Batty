// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DemoCut",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "democut", path: "Sources/democut")
    ]
)
