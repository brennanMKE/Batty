// swift-tools-version: 6.3
import PackageDescription

// Important: Use these settings for most targets.
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
            url: "https://github.com/brennanMKE/libghostty-spm",
            revision: "ef88eedfdd7765cadcf131e426afd62f4565fec7"
        ),
        .package(path: "../../SlidingTabs"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(
            url: "https://github.com/gonzalezreal/textual.git",
            revision: "5b06b811c0f5313b6b84bbef98c635a630638c38"
        ),
    ],
    targets: [
        .target(
            name: "BattyKit",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "SlidingTabs", package: "SlidingTabs"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Textual", package: "textual"),
            ],
            resources: [
                .process("Resources"),
                .copy("Help"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BattyKitTests",
            dependencies: ["BattyKit"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
