// BackgroundCatalogParserTests.swift

import Foundation
import Testing
@testable import BattyKit

/// A catalog as JSON objects, so each test changes one field.
nonisolated enum CatalogJSON {
    static let url = URL(string: "https://batty.sstools.co/backgrounds/catalog.json")!

    static func image(_ name: String) -> [String: Any] {
        ["title": "Title \(name)", "full": "\(name).png", "thumbnail": "\(name)-thumb.png"]
    }

    static func set(_ name: String, images: [[String: Any]]) -> [String: Any] {
        ["name": "Set \(name)", "images": images]
    }

    static func catalog(sets: [[String: Any]] = [set("one", images: [image("one-01"), image("one-02")])]) -> [String: Any] {
        ["sets": sets]
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func parse(_ object: Any) throws(BackgroundCatalogError) -> BackgroundCatalog {
        try BackgroundCatalogParser.parse(data(object), catalogURL: url)
    }

    static func error(_ object: Any) -> BackgroundCatalogError? {
        do {
            _ = try parse(object)
            return nil
        } catch {
            return error
        }
    }

    /// Sets `value` at a dotted path such as `sets[0].images[1].full`; nil removes the key.
    static func setting(_ path: String, to value: Any?, in object: [String: Any] = catalog()) -> [String: Any] {
        var parts: [Any] = []
        for component in path.split(separator: ".") {
            var text = Substring(component)
            if let bracket = text.firstIndex(of: "[") {
                parts.append(String(text[..<bracket]))
                text = text[bracket...]
                while let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") {
                    parts.append(Int(text[text.index(after: open)..<close])!)
                    text = text[text.index(after: close)...]
                }
            } else {
                parts.append(String(text))
            }
        }
        return apply(parts[...], value: value, to: object) as! [String: Any]
    }

    private static func apply(_ parts: ArraySlice<Any>, value: Any?, to node: Any) -> Any {
        guard let first = parts.first else { return value as Any }
        let rest = parts.dropFirst()
        if let key = first as? String, var dict = node as? [String: Any] {
            if rest.isEmpty {
                dict[key] = value
            } else {
                dict[key] = apply(rest, value: value, to: dict[key] as Any)
            }
            return dict
        }
        if let index = first as? Int, var array = node as? [Any] {
            array[index] = rest.isEmpty ? value as Any : apply(rest, value: value, to: array[index])
            return array
        }
        return node
    }
}

struct BackgroundCatalogParserTests {
    @Test func catalogOnMainParses() throws {
        // #filePath: .../BattyKit/Tests/BattyKitTests/BackgroundCatalogParserTests.swift
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("website/backgrounds/catalog.json"))
        let catalog = try BackgroundCatalogParser.parse(data, catalogURL: BackgroundCatalog.builtInURL)
        #expect(!catalog.sets.isEmpty)
        for image in catalog.allImages {
            #expect(image.full.absoluteString.hasPrefix("https://batty.sstools.co/backgrounds/"))
            #expect(image.thumbnail.absoluteString.hasPrefix("https://batty.sstools.co/backgrounds/"))
            #expect(BackgroundCatalogLimits.isAccepted(type: "public.png", for: image.full) || BackgroundCatalogLimits.isAccepted(type: "public.jpeg", for: image.full))
        }
    }

    @Test func theFormatsExampleParses() throws {
        let json = """
        {
          "sets": [
            { "name": "Future Cities",
              "images": [
                { "title": "Skyline in the Fog", "thumbnail": "future-cities/01-skyline-fog-thumb.png", "full": "future-cities/01-skyline-fog.png" },
                { "thumbnail": "future-cities/02-night-rail-thumb.png", "full": "future-cities/02-night-rail.png" }
              ] }
          ]
        }
        """
        let catalog = try BackgroundCatalogParser.parse(Data(json.utf8), catalogURL: BackgroundCatalog.builtInURL)
        #expect(catalog.sets.map(\.name) == ["Future Cities"])
        #expect(catalog.allImages.map(\.title) == ["Skyline in the Fog", "02-night-rail"])
        #expect(catalog.allImages[0].full.absoluteString == "https://batty.sstools.co/backgrounds/future-cities/01-skyline-fog.png")
        #expect(catalog.allImages[0].thumbnail.absoluteString == "https://batty.sstools.co/backgrounds/future-cities/01-skyline-fog-thumb.png")
        #expect(catalog.allImages[0].id == catalog.allImages[0].full)
    }

    @Test func unknownFieldsAreIgnored() throws {
        var object = CatalogJSON.setting("sets[0].images[0].mood", to: "calm")
        object["future"] = ["anything": true]
        object["schemaVersion"] = 1
        let catalog = try CatalogJSON.parse(object)
        #expect(catalog.allImages.count == 2)
    }

    @Test(arguments: [
        "sets", "sets[0].name", "sets[0].images", "sets[0].images[1].full", "sets[0].images[1].thumbnail",
    ])
    func missingRequiredFieldNamesItsPath(_ path: String) {
        let error = CatalogJSON.error(CatalogJSON.setting(path, to: nil))
        #expect(error == .invalid(path: path))
        #expect(error?.message == "Not a background catalog: \(path)")
    }

    @Test(arguments: [
        ("sets", "x"), ("sets[0].name", 3), ("sets[0].images", "x"), ("sets[0].images[1].title", ["a"]),
        ("sets[0].images[1].thumbnail", 7), ("sets[0].images[1].full", ["url": "x.png"]), ("sets[0].images[1].full", "  "),
    ] as [(String, any Sendable)])
    func wronglyTypedFieldNamesItsPath(_ path: String, _ value: any Sendable) {
        #expect(CatalogJSON.error(CatalogJSON.setting(path, to: value)) == .invalid(path: path))
    }

    @Test func missingOrBlankTitleFallsBackToTheFileName() throws {
        let missing = try CatalogJSON.parse(CatalogJSON.setting("sets[0].images[0].title", to: nil))
        #expect(missing.allImages[0].title == "one-01")
        let blank = try CatalogJSON.parse(CatalogJSON.setting("sets[0].images[0].title", to: "  "))
        #expect(blank.allImages[0].title == "one-01")
    }

    @Test func duplicateSetNamesAreAllowed() throws {
        let object = CatalogJSON.catalog(sets: [
            CatalogJSON.set("one", images: [CatalogJSON.image("a")]),
            CatalogJSON.set("one", images: [CatalogJSON.image("b")]),
        ])
        let catalog = try CatalogJSON.parse(object)
        #expect(catalog.sets.map(\.id) == [0, 1])
    }

    @Test func theSameFullSizeURLTwiceIsRejected() {
        let object = CatalogJSON.catalog(sets: [
            CatalogJSON.set("one", images: [CatalogJSON.image("a")]),
            CatalogJSON.set("two", images: [CatalogJSON.image("b"), CatalogJSON.image("a")]),
        ])
        #expect(CatalogJSON.error(object) == .invalid(path: "sets[1].images[1].full"))
    }

    @Test(arguments: ["http://batty.sstools.co/a.png", "file:///etc/passwd", "data:image/png;base64,AAAA"])
    func nonHTTPSResolvedURLIsRejected(_ url: String) {
        for path in ["sets[0].images[0].full", "sets[0].images[0].thumbnail"] {
            #expect(CatalogJSON.error(CatalogJSON.setting(path, to: url)) == .invalid(path: path))
        }
    }

    @Test func relativeURLsResolveAgainstTheCatalogURL() throws {
        let catalog = try CatalogJSON.parse(CatalogJSON.setting("sets[0].images[0].full", to: "one/a.png"))
        #expect(catalog.allImages[0].full.absoluteString == "https://batty.sstools.co/backgrounds/one/a.png")
        #expect(catalog.allImages[0].thumbnail.absoluteString == "https://batty.sstools.co/backgrounds/one-01-thumb.png")
    }

    @Test func absoluteHTTPSURLOnAnotherHostIsAllowed() throws {
        let catalog = try CatalogJSON.parse(CatalogJSON.setting("sets[0].images[0].full", to: "https://cdn.example.com/x.png"))
        #expect(catalog.allImages[0].full.host == "cdn.example.com")
    }

    @Test func stringLengthLimitsAreEnforcedAfterTrimming() throws {
        let padded = "  " + String(repeating: "t", count: 100) + "  "
        #expect(try CatalogJSON.parse(CatalogJSON.setting("sets[0].name", to: padded)).sets[0].name.count == 100)
        let path = "sets[0].name"
        #expect(CatalogJSON.error(CatalogJSON.setting(path, to: String(repeating: "t", count: 101))) == .invalid(path: path))
        #expect(CatalogJSON.error(CatalogJSON.setting(path, to: "   ")) == .invalid(path: path))
        let title = "sets[0].images[0].title"
        #expect(CatalogJSON.error(CatalogJSON.setting(title, to: String(repeating: "t", count: 101))) == .invalid(path: title))
    }

    @Test func setAndImageCountLimitsAreEnforced() {
        let tooManySets = (0...BackgroundCatalogLimits.sets).map { CatalogJSON.set("s\($0)", images: []) }
        #expect(CatalogJSON.error(CatalogJSON.catalog(sets: tooManySets)) == .invalid(path: "sets"))
        let tooManyImages = (0...BackgroundCatalogLimits.imagesPerSet).map { CatalogJSON.image("i\($0)") }
        #expect(CatalogJSON.error(CatalogJSON.catalog(sets: [CatalogJSON.set("s", images: tooManyImages)])) == .invalid(path: "sets[0].images"))
        let full = (0..<11).map { set in
            CatalogJSON.set("s\(set)", images: (0..<100).map { CatalogJSON.image("i\(set)-\($0)") })
        }
        #expect(CatalogJSON.error(CatalogJSON.catalog(sets: full)) == .invalid(path: "sets[10].images"))
    }

    @Test func htmlBodyIsNotACatalog() {
        let html = Data("<html><body>Not here</body></html>".utf8)
        #expect(throws: BackgroundCatalogError.invalid(path: "(root)")) {
            try BackgroundCatalogParser.parse(html, catalogURL: CatalogJSON.url)
        }
    }

    @Test func bodyOverOneMegabyteIsTooLarge() {
        let big = Data(repeating: 0x20, count: BackgroundCatalogLimits.catalogBytes + 1)
        #expect(throws: BackgroundCatalogError.tooLarge) {
            try BackgroundCatalogParser.parse(big, catalogURL: CatalogJSON.url)
        }
        #expect(BackgroundCatalogError.tooLarge.message == "Catalog is larger than 1 MB")
    }

    @Test func displayTextStripsControlCharacters() {
        #expect(BackgroundCatalogParser.displayText("Sky\u{0007}line\n\u{202E}Fog") == "SkylineFog")
    }
}
