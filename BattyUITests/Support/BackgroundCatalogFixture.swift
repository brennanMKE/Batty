// BackgroundCatalogFixture.swift

import CoreGraphics
import CryptoKit
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
    static func write(in folder: URL, omitting: String? = nil, sets setList: [String] = setIDs) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sets: [[String: Any]] = []
        for (setIndex, set) in setList.enumerated() {
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

    /// The shipped catalog, `website/backgrounds/catalog.json`, with every set, title
    /// and path as published. Each thumbnail is a plain 480 x 300 PNG, the shipped
    /// thumbnails' size, because the real ones live in Git LFS.
    static func writeShipped(in folder: URL) throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "website/backgrounds/catalog.json")
        let data = try Data(contentsOf: source)
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sets = try XCTUnwrap(catalog["sets"] as? [[String: Any]])
        for (setIndex, set) in sets.enumerated() {
            let images = try XCTUnwrap(set["images"] as? [[String: Any]])
            for (index, image) in images.enumerated() {
                let thumbnail = folder.appending(path: try XCTUnwrap(image["thumbnail"] as? String))
                try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png(width: 480, height: 300, seed: setIndex * 10 + index).write(to: thumbnail)
            }
        }
        try data.write(to: folder.appending(path: "catalog.json"))
    }

    /// Marks the built-in catalog's images at `fullPaths` as already downloaded,
    /// the way `HostedImageStore` leaves them: a PNG in `<hostedFolder>/<digest>/`
    /// named for its own SHA-256, and a `hosted-images.json` record keyed by the
    /// image's resolved full URL. The app then shows "Available offline" on them.
    static func seedDownloaded(_ fullPaths: [String], into hostedFolder: URL) throws {
        var records: [[String: Any]] = []
        for (index, path) in fullPaths.enumerated() {
            let data = try png(width: 96, height: 60, seed: 50 + index)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let folder = hostedFolder.appending(path: digest)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stem = (path as NSString).lastPathComponent
            try data.write(to: folder.appending(path: stem))
            records.append(["url": "https://batty.sstools.co/backgrounds/" + path, "digest": digest, "fetchedAt": 0])
        }
        try JSONSerialization.data(withJSONObject: records).write(to: hostedFolder.appending(path: "hosted-images.json"))
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

    /// Keeps the app's download of `imageID`'s full-size file waiting until `release`.
    static func hold(_ imageID: String, in folder: URL) throws {
        try Data().write(to: folder.appending(path: fullPath(imageID) + ".hold"))
    }

    static func release(_ imageID: String, in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appending(path: fullPath(imageID) + ".hold"))
    }
}
