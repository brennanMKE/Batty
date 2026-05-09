// swift-tools-version: 6.3
import PackageDescription

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
    ],
    targets: [
        .target(
            name: "BattyKit",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .testTarget(
            name: "BattyKitTests",
            dependencies: ["BattyKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
