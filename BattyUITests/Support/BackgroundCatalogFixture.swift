// BackgroundCatalogFixture.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// A folder standing in for `https://batty.sstools.co/backgrounds/`: three sets
/// of two small PNGs with thumbnails. The app
/// serves it through its fixture fetcher and logs each requested path to
/// `requests.log`, so a UI test never reaches the website.
nonisolated enum BackgroundCatalogFixture {
    static let envVar = "BATTY_UI_TEST_BACKGROUND_CATALOG_DIR"
    static let setIDs = ["future-cities", "cool-vehicles", "beautiful-landscapes"]

    /// The name a set's section is identified by.
    static func setName(_ id: String) -> String { "Set \(id)" }

    static func imageIDs(in set: String) -> [String] { ["\(set)-01", "\(set)-02"] }

    static func fullPath(_ imageID: String) -> String { "\(imageID).png" }
    static func thumbnailPath(_ imageID: String) -> String { "\(imageID)-thumb.png" }

    /// `omitting` leaves that image's full-size file out, so choosing it fails.
    static func write(in folder: URL, omitting: String? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sets: [[String: Any]] = []
        for (setIndex, set) in setIDs.enumerated() {
            var images: [[String: Any]] = []
            for (index, id) in imageIDs(in: set).enumerated() {
                let full = try png(width: 96, height: 64, seed: setIndex * 10 + index)
                let thumb = try png(width: 48, height: 32, seed: setIndex * 10 + index)
                if id != omitting { try full.write(to: folder.appending(path: fullPath(id))) }
                try thumb.write(to: folder.appending(path: thumbnailPath(id)))
                images.append(["title": "Picture \(id)", "full": fullPath(id), "thumbnail": thumbnailPath(id)])
            }
            sets.append(["name": setName(set), "images": images])
        }
        let catalog: [String: Any] = ["sets": sets]
        try JSONSerialization.data(withJSONObject: catalog).write(to: folder.appending(path: "catalog.json"))
    }

    /// A user catalog on another host, served from `hosts/<host>/`: one set
    /// of two small PNGs whose ids start with `setName`'s lowercased words.
    static func writeHostedCatalog(in folder: URL, host: String, path: String = "catalog.json", setName: String) throws {
        let root = folder.appending(path: "hosts/\(host)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var images: [[String: Any]] = []
        for id in hostedImageIDs(setName: setName) {
            try png(width: 96, height: 64, seed: id.count).write(to: root.appending(path: fullPath(id)))
            try png(width: 48, height: 32, seed: id.count).write(to: root.appending(path: thumbnailPath(id)))
            images.append(["title": "Picture \(id)", "full": fullPath(id), "thumbnail": thumbnailPath(id)])
        }
        let catalog: [String: Any] = ["sets": [["name": setName, "images": images]]]
        try JSONSerialization.data(withJSONObject: catalog).write(to: root.appending(path: path))
    }

    static func hostedImageIDs(setName: String) -> [String] {
        let stem = setName.lowercased().split(separator: " ").joined(separator: "-")
        return ["\(stem)-01", "\(stem)-02"]
    }

    /// An HTML page where a catalog is expected.
    static func writeHTML(in folder: URL, host: String, path: String = "catalog.json") throws {
        let root = folder.appending(path: "hosts/\(host)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><body>Not a catalog</body></html>".utf8).write(to: root.appending(path: path))
    }

    static func requests(in folder: URL) -> [String] {
        let text = (try? String(contentsOf: folder.appending(path: "requests.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private static func png(width: Int, height: Int, seed: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: Double(seed % 7) / 7, green: 0.5, blue: Double(seed % 5) / 5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
}
