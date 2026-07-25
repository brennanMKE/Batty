// swift-tools-version: 6.3
import PackageDescription

// Important: Use these settings for every target, including tests.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .defaultIsolation(MainActor.self),
]

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
        .executable(
            name: "batty",
            targets: ["batty"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/libghostty-spm",
            revision: "c69c34354e511af7a3e6d7e5e2a4fa2fed4b90ff"
        ),
        .package(path: "../../SlidingTabs"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(
            url: "https://github.com/gonzalezreal/textual.git",
            revision: "5b06b811c0f5313b6b84bbef98c635a630638c38"
        ),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Dependency-free core shared by the GUI app and the `batty` CLI.
        // Keeping it free of Sparkle/libghostty/etc. lets the CLI link only
        // this — otherwise the CLI transitively drags in Sparkle and crashes
        // at launch from the app bundle (no rpath to Contents/Frameworks).
        .target(
            name: "BattyCLICore",
            swiftSettings: swiftSettings
        ),
        // Dependency-free shared XPC contract (protocol trio, JSON-in-Data
        // payloads, service names, exit codes) for the app, the broker
        // agent (#0270), and the `batty` CLI (#0271). Foundation only, no
        // product dependencies — same discipline as BattyCLICore, and for
        // the same reason: the broker sits outside Contents/Frameworks/
        // reach just like the CLI does, so anything it links must not
        // transitively drag in Sparkle/libghostty/etc.
        .target(
            name: "BattyXPCCore",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BattyKit",
            dependencies: [
                "BattyCLICore",
                "BattyXPCCore",
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
        .executableTarget(
            name: "batty",
            dependencies: [
                "BattyCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
