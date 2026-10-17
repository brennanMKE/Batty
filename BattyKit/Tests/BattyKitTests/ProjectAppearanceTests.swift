// ProjectAppearanceTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Observation
import os
import SwiftUI
import Testing
@testable import BattyKit

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

@MainActor
struct ProjectAppearanceTests {
    @Test func normalizedHexAcceptsSixDigitsWithOrWithoutHashAndUppercases() {
        #expect(ProjectAppearance.normalizedHex("#1a2b3c") == "#1A2B3C")
        #expect(ProjectAppearance.normalizedHex("1A2B3C") == "#1A2B3C")
        #expect(ProjectAppearance.normalizedHex("  #1a2b3c ") == "#1A2B3C")
        for bad in ["", "#12", "#GGGGGG", "#1234567", "red"] { #expect(ProjectAppearance.normalizedHex(bad) == nil, "\(bad)") }
        #expect(ProjectAppearance.normalizedHex(nil) == nil)
    }

    @Test func hexClampsAndRounds() {
        #expect(ProjectAppearance.hex(red: 1, green: 0, blue: 0.5) == "#FF0080")
        #expect(ProjectAppearance.hex(red: 2, green: -1, blue: 0) == "#FF0000")
    }

    @Test func everyPaletteEntryIsItsOwnNearestEntry() {
        for entry in SessionColor.allCases {
            #expect(ProjectAppearance.nearestPalette(toHex: entry.hexString) == entry, "\(entry)")
        }
    }

    @Test func nearestPaletteMapsArbitraryColors() {
        #expect(ProjectAppearance.nearestPalette(toHex: "#FF0000") == .red)
        #expect(ProjectAppearance.nearestPalette(toHex: "#0000FF") == .blue)
        #expect(ProjectAppearance.nearestPalette(toHex: "#00FF00") == .green)
        #expect(ProjectAppearance.nearestPalette(toHex: "#FFD000") == .amber)
        #expect(ProjectAppearance.nearestPalette(toHex: "#7A4FB0") == .violet)
        #expect(ProjectAppearance.nearestPalette(toHex: "garbage") == .blue)
    }

    @Test func aLegacySymbolNameResolvesToItsCaseAndAnythingElseToFolderWithAName() {
        #expect(ProjectAppearance.resolve(symbol: .folder, customName: "sparkles").symbol == .ai)
        #expect(ProjectAppearance.resolve(symbol: .folder, customName: "sparkles").customName == nil)
        let custom = ProjectAppearance.resolve(symbol: .chip, customName: " flame.fill ")
        #expect(custom.symbol == .folder && custom.customName == "flame.fill")
        let none = ProjectAppearance.resolve(symbol: .chip, customName: "  ")
        #expect(none.symbol == .chip && none.customName == nil)
    }

    @Test func aCustomColorEqualToAPaletteEntryIsStoredAsThatEntry() {
        let exact = ProjectAppearance.resolve(color: .blue, customHex: SessionColor.red.hexString.lowercased())
        #expect(exact.color == .red && exact.customHex == nil)
        let custom = ProjectAppearance.resolve(color: .blue, customHex: "#FF0001")
        #expect(custom.color == .red && custom.customHex == "#FF0001")
    }

    @Test func drawingFallsBackWhenTheNameOrColorIsUnusable() {
        #expect(ProjectAppearance.systemName(symbol: .ai, customName: "no.such.symbol.name") == "sparkles")
        #expect(ProjectAppearance.systemName(symbol: .folder, customName: "flame.fill") == "flame.fill")
        #expect(ProjectAppearance.systemName(symbol: .folder, customName: nil) == "folder.fill")
        #expect(ProjectAppearance.color(palette: .teal, customHex: "nope") == SessionColor.teal.color)
        #expect(ProjectAppearance.color(palette: .teal, customHex: "#010203") != SessionColor.teal.color)
    }

    @Test func everyLegacyCaseMapsToItsSystemNameAndBack() {
        #expect(ProjectSymbol.allCases.count == 36)
        for symbol in ProjectSymbol.allCases {
            #expect(ProjectAppearance.legacySymbol(forSystemName: symbol.systemName) == symbol)
            #expect(Project(name: "P", rootPath: "/tmp/p", symbol: symbol, customSymbolName: symbol.systemName).customSymbolName == nil)
        }
    }
}

@MainActor
struct ProjectAppearanceCodingTests {
    private let layoutJSON = String(decoding: try! ProjectsFile.encoder.encode(ProjectLayout.preset(.singlePane)), as: UTF8.self)

    private func json(extra: String, color: String = "2", symbol: String = "\"ai\"") -> Data {
        Data(#"{"id":"\#(UUID().uuidString)","name":"P","rootPath":"/tmp/p","color":\#(color),"symbol":\#(symbol)\#(extra),"layout":\#(layoutJSON)}"#.utf8)
    }

    private func object(_ project: Project) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(project)) as? [String: Any])
    }

    @Test func aLegacyFileLoadsUnchangedAndSavesWithoutNewKeys() throws {
        let project = try ProjectsFile.decoder.decode(Project.self, from: json(extra: ""))
        #expect(project.color == .green && project.symbol == .ai)
        #expect(project.customColorHex == nil && project.customSymbolName == nil)
        let written = try object(project)
        #expect(written["color"] as? Int == SessionColor.green.rawValue)
        #expect(written["symbol"] as? String == "ai")
        #expect(written["customColor"] == nil && written["symbolName"] == nil)
    }

    @Test func customValuesRoundTripAndLegacyKeysCarryTheNearestValues() throws {
        let original = Project(name: "P", rootPath: "/tmp/p", color: .blue, symbol: .chip, customColorHex: "#FE0102", customSymbolName: "flame.fill")
        #expect(original.color == .red && original.symbol == .folder)
        let written = try object(original)
        #expect(written["customColor"] as? String == "#FE0102")
        #expect(written["symbolName"] as? String == "flame.fill")
        #expect(written["color"] as? Int == SessionColor.red.rawValue)
        #expect(written["symbol"] as? String == "folder")
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: ProjectsFile.encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.displayColor == ProjectAppearance.color(palette: .red, customHex: "#FE0102"))
        #expect(decoded.displaySystemName == "flame.fill")
    }

    @Test func aLegacyDecoderSeesValidOldKeysAndIgnoresTheNewOnes() throws {
        struct Legacy: Decodable {
            var color: SessionColor
            var symbol: ProjectSymbol
        }
        let original = Project(name: "P", rootPath: "/tmp/p", customColorHex: "#00FF01", customSymbolName: "flame.fill")
        let legacy = try ProjectsFile.decoder.decode(Legacy.self, from: ProjectsFile.encoder.encode(original))
        #expect(legacy.color == .green)
        #expect(legacy.symbol == .folder)
    }

    @Test func aMalformedCustomColorFallsBackToTheLegacyColorAndKeepsTheProject() throws {
        let project = try ProjectsFile.decoder.decode(Project.self, from: json(extra: #","customColor":"not-a-color""#))
        #expect(project.color == .green && project.customColorHex == nil)
        let wrongType = try ProjectsFile.decoder.decode(Project.self, from: json(extra: #","customColor":12,"symbolName":7"#))
        #expect(wrongType.color == .green && wrongType.customColorHex == nil && wrongType.customSymbolName == nil && wrongType.symbol == .ai)
    }

    @Test func anUnshippedSymbolNameIsKeptButDrawsTheLegacyGlyph() throws {
        let project = try ProjectsFile.decoder.decode(Project.self, from: json(extra: #","symbolName":"not.a.real.symbol.name""#, symbol: "\"folder\""))
        #expect(project.customSymbolName == "not.a.real.symbol.name")
        #expect(project.displaySystemName == "folder.fill")
    }

    @Test func aSyncRecordCarriesCustomValuesAndDecodesOnALegacyShape() throws {
        struct LegacyRecord: Decodable {
            var id: UUID
            var color: SessionColor
            var symbol: ProjectSymbol
        }
        let project = Project(name: "P", rootPath: "/tmp/p", isShared: true, customColorHex: "#FE0102", customSymbolName: "flame.fill")
        let record = project.syncRecord(home: "/Users/x")
        #expect(record.customColor == "#FE0102" && record.symbolName == "flame.fill")
        let data = try ProjectsFile.encoder.encode(record)
        #expect(try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: data) == record)
        let legacy = try ProjectsFile.decoder.decode(LegacyRecord.self, from: data)
        #expect(legacy.color == .red && legacy.symbol == .folder)
        let restored = Project(syncRecord: record, home: "/Users/x")
        #expect(restored.customColorHex == "#FE0102" && restored.customSymbolName == "flame.fill")
    }

    @Test func aSyncRecordFromAnOlderPeerHasNoCustomValues() throws {
        let record = Project(name: "P", rootPath: "/tmp/p", color: .pink, symbol: .ai, isShared: true).syncRecord(home: "/Users/x")
        let object = try #require(JSONSerialization.jsonObject(with: ProjectsFile.encoder.encode(record)) as? [String: Any])
        #expect(object["customColor"] == nil && object["symbolName"] == nil)
        let decoded = try ProjectsFile.decoder.decode(ProjectSyncRecord.self, from: ProjectsFile.encoder.encode(record))
        #expect(decoded.customColor == nil && decoded.symbolName == nil && decoded.color == .pink && decoded.symbol == .ai)
    }
}

@MainActor
struct ProjectAppearanceEditingTests {
    private func draftModel() throws -> (ProjectEditorViewModel, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"))
        let project = Project(name: "P", rootPath: base.path, color: .violet, symbol: .chip)
        try store.upsert(project)
        return (ProjectEditorViewModel(store: store, initialSelection: project.id), base)
    }

    @Test func settingACustomColorAndSymbolEditsTheDraftAndSurvivesSave() throws {
        let (model, base) = try draftModel()
        defer { try? FileManager.default.removeItem(at: base) }
        model.setCustomColor(hex: "#FE0102")
        model.setSymbolName("flame.fill")
        #expect(model.draft?.color == .red && model.draft?.customColorHex == "#FE0102")
        #expect(model.draft?.symbol == .folder && model.draft?.customSymbolName == "flame.fill")
        let made = try #require(model.draft?.makeProject())
        #expect(made.customColorHex == "#FE0102" && made.customSymbolName == "flame.fill")
    }

    @Test func pickingAPaletteSwatchOrLegacySymbolClearsTheCustomValues() throws {
        let (model, base) = try draftModel()
        defer { try? FileManager.default.removeItem(at: base) }
        model.setCustomColor(hex: "#FE0102")
        model.setSymbolName("flame.fill")
        model.setColor(.teal)
        model.setSymbol(.ai)
        #expect(model.draft?.color == .teal && model.draft?.customColorHex == nil)
        #expect(model.draft?.symbol == .ai && model.draft?.customSymbolName == nil)
    }

    @Test func aSymbolNameEqualToALegacyGlyphIsStoredAsTheLegacyCase() throws {
        let (model, base) = try draftModel()
        defer { try? FileManager.default.removeItem(at: base) }
        model.setSymbolName("sparkles")
        #expect(model.draft?.symbol == .ai && model.draft?.customSymbolName == nil)
        model.setCustomColor(hex: SessionColor.pink.hexString)
        #expect(model.draft?.color == .pink && model.draft?.customColorHex == nil)
    }

    @Test func malformedValuesAreIgnored() throws {
        let (model, base) = try draftModel()
        defer { try? FileManager.default.removeItem(at: base) }
        let before = model.draft
        model.setCustomColor(hex: "nonsense")
        model.setSymbolName("   ")
        #expect(model.draft == before)
    }

    private func notifies(_ model: ProjectEditorViewModel, _ write: () -> Void) -> Bool {
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking({ _ = model.draft }, onChange: { fired.withLock { $0 = true } })
        write()
        return fired.withLock { $0 }
    }

    @Test func equalWritesDoNotNotifyObservers() throws {
        let (model, base) = try draftModel()
        defer { try? FileManager.default.removeItem(at: base) }
        // The fixture draft is violet with the chip symbol and no custom values.
        #expect(!notifies(model) { model.setColor(.violet) })
        #expect(!notifies(model) { model.setSymbol(.chip) })
        #expect(!notifies(model) { model.setCustomColor(hex: SessionColor.violet.hexString) })

        #expect(notifies(model) { model.setCustomColor(hex: "#FE0102") })
        #expect(!notifies(model) { model.setCustomColor(hex: "#fe0102") })
        #expect(notifies(model) { model.setSymbolName("flame.fill") })
        #expect(!notifies(model) { model.setSymbolName("flame.fill") })
    }

    @Test func aProjectWithCustomValuesOpensASessionWithTheNearestPaletteColor() throws {
        let project = Project(name: "P", rootPath: NSTemporaryDirectory(), color: .blue, symbol: .folder, customColorHex: "#FE0102", customSymbolName: "flame.fill")
        let bellFeed = BellFeedStore()
        let window = WindowRuntime(bellFeed: bellFeed, nameCache: SessionNameCache(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json")))
        let tree = try ProjectTreeBuilder.build(project: project, contentFactory: noContent, isSessionSelected: true)
        let session = window.addProjectSession(project, tree: tree)
        #expect(session.colorIndex == SessionColor.red.rawValue)
        #expect(session.projectSymbolName == "flame.fill")
    }
}

@MainActor
struct SFSymbolCatalogTests {
    @Test func parseSkipsCommentsAndBlankLines() {
        let entries = SFSymbolCatalog.parse("# header\n\nflame\t14\n  star.fill \n#x\ncloud\t15\n")
        #expect(entries == [.init(name: "flame", minMacOS: 14), .init(name: "star.fill", minMacOS: 0), .init(name: "cloud", minMacOS: 15)])
    }

    @Test func loadKeepsOnlyEntriesTheRunningOSShips() {
        let entries: [SFSymbolCatalog.Entry] = [
            .init(name: "flame", minMacOS: 11), .init(name: "newer", minMacOS: 26), .init(name: "flame", minMacOS: 11), .init(name: "star", minMacOS: 0),
        ]
        #expect(SFSymbolCatalog(entries: entries, osMajor: 15).names == ["flame", "star"])
        #expect(SFSymbolCatalog(entries: entries, osMajor: 26).names == ["flame", "newer", "star"])
        #expect(SFSymbolCatalog(entries: entries, osMajor: 10).names == ["star"])
    }

    @Test func bundledLoadFiltersByVersionAndKeepsLegacyNames() {
        let old = SFSymbolCatalog.bundled(osMajor: 11)
        let current = SFSymbolCatalog.bundled(osMajor: 99)
        #expect(old.names.count < current.names.count)
        for symbol in ProjectSymbol.allCases { #expect(old.names.contains(symbol.systemName), "\(symbol.systemName)") }
        #expect(!current.names.contains { $0.hasPrefix("airpods") || $0.hasPrefix("macbook") })
    }

    @Test func filteringIsCaseInsensitiveSubstringWithAllWordsRequired() {
        let catalog = SFSymbolCatalog(names: ["flame", "flame.fill", "flame.circle", "star.fill", "cloud.sun.fill"], isAvailable: { _ in true })
        #expect(catalog.filtered("FLAME") == ["flame", "flame.fill", "flame.circle"])
        #expect(catalog.filtered("fill") == ["flame.fill", "star.fill", "cloud.sun.fill"])
        #expect(catalog.filtered("cloud fill") == ["cloud.sun.fill"])
        #expect(catalog.filtered("zzz").isEmpty)
        #expect(catalog.filtered("  ") == catalog.names)
    }

    @Test func rankingPutsTheExactNameFirstThenPrefixesThenOtherMatches() {
        let catalog = SFSymbolCatalog(names: ["a.flame", "flame.fill", "flame.circle", "flame", "x.flame.y"], isAvailable: { _ in true })
        #expect(catalog.filtered("flame") == ["flame", "flame.fill", "flame.circle", "a.flame", "x.flame.y"])
        #expect(catalog.filtered("FLAME.circle") == ["flame.circle"])
    }

    @Test func anEmptyFilterListsSuggestedFirstThenTheRestWithoutDuplicates() {
        let catalog = SFSymbolCatalog(names: ["flame", "folder.fill", "sparkles"], isAvailable: { _ in true })
        let listing = catalog.listing(for: "")
        #expect(listing.suggestedCount == 36)
        #expect(listing.names.first == "folder.fill")
        #expect(listing.names.last == "flame")
        #expect(Set(listing.names).count == listing.names.count)
        let filtered = catalog.listing(for: "flame")
        #expect(filtered.names == ["flame"] && filtered.suggestedCount == 0)
    }

    @Test func theBundledListLoadsAndContainsEveryLegacySymbol() {
        let catalog = SFSymbolCatalog.shared
        #expect(catalog.names.count > 3000)
        let names = Set(catalog.names)
        for symbol in ProjectSymbol.allCases { #expect(names.contains(symbol.systemName), "\(symbol.systemName)") }
        for symbol in ProjectSymbol.allCases { #expect(SFSymbolCatalog.systemDraws(symbol.systemName)) }
        #expect(!catalog.filtered("flame").isEmpty)
    }

    @Test func theListCursorClampsAtEdgesAndLandsOnTheLastPartialRow() {
        let nine = ProjectSymbolListCursor.columns
        #expect(ProjectSymbolListCursor(0, count: 20).moved(.left).index == 0)
        #expect(ProjectSymbolListCursor(0, count: 20).moved(.up).index == 0)
        #expect(ProjectSymbolListCursor(nine - 1, count: 20).moved(.right).index == nine - 1)
        #expect(ProjectSymbolListCursor(1, count: 20).moved(.down).index == 1 + nine)
        #expect(ProjectSymbolListCursor(nine + 5, count: 20).moved(.down).index == 19)
        #expect(ProjectSymbolListCursor(19, count: 20).moved(.right).index == 19)
        #expect(ProjectSymbolListCursor(5, count: 0).moved(.down).index == 0)
    }
}

@MainActor
struct SheetReturnKeyMonitorTests {
    private func key(_ code: UInt16, chars: String = "\r", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private let editor = ProjectEditorWindowController.windowIdentifier

    @Test func aPlainReturnInASheetOfTheEditorWindowChooses() {
        #expect(SheetReturnKeyMonitor.isChooseKey(key(36), isSheet: true, sheetParentIdentifier: editor))
        #expect(SheetReturnKeyMonitor.isChooseKey(key(76), isSheet: true, sheetParentIdentifier: editor))
    }

    @Test func aSheetOfAnotherWindowKeepsItsReturn() {
        #expect(!SheetReturnKeyMonitor.isChooseKey(key(36), isSheet: true, sheetParentIdentifier: nil))
        #expect(!SheetReturnKeyMonitor.isChooseKey(key(36), isSheet: true, sheetParentIdentifier: "main"))
    }

    @Test func theEditorWindowItselfIsNotASheet() {
        #expect(!SheetReturnKeyMonitor.isChooseKey(key(36), isSheet: false, sheetParentIdentifier: editor))
    }

    @Test func aHeldModifierOrAnotherKeyIsLeftAlone() {
        for modifier: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            #expect(!SheetReturnKeyMonitor.isChooseKey(key(36, modifiers: modifier), isSheet: true, sheetParentIdentifier: editor))
        }
        #expect(!SheetReturnKeyMonitor.isChooseKey(key(53, chars: "\u{1B}"), isSheet: true, sheetParentIdentifier: editor))
        #expect(!SheetReturnKeyMonitor.isChooseKey(key(0, chars: "a"), isSheet: true, sheetParentIdentifier: editor))
    }
}
