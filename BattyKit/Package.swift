// swift-tools-version: 6.3
import PackageDescription

// Important: Use these settings for all libraries except CommunityCore.
let swiftSettings: [SwiftSetting]? = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "BattyKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "BattyKit",
            targets: ["BattyKit"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/libghostty-spm",
            exact: "1.0.1777879537"
        ),
        .package(path: "../../SlidingTabs"),
    ],
    targets: [
        .target(
            name: "BattyKit",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "SlidingTabs", package: "SlidingTabs"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BattyKitTests",
            dependencies: ["BattyKit"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
