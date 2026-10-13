// ProjectSymbolTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

private let pinnedKeys = [
    "folder", "terminal", "code", "hammer", "tools", "package",
    "branch", "checklist", "extension", "macApp", "iPhoneApp", "web",
    "server", "cloud", "network", "security", "link", "qrCode",
    "chip", "wireless", "light", "home", "art", "grid",
    "craft", "video", "game", "document", "learning", "chart",
    "calendar", "social", "community", "ai", "model", "map",
]

@MainActor
struct ProjectSymbolCatalogTests {
    @Test func catalogHasThirtySixCasesInTheDeclaredOrder() {
        #expect(ProjectSymbol.allCases.count == 36)
        #expect(ProjectSymbol.allCases.map(\.rawValue) == pinnedKeys)
    }

    @Test func keysAndSystemNamesAreUnique() {
        #expect(Set(ProjectSymbol.allCases.map(\.rawValue)).count == 36)
        #expect(Set(ProjectSymbol.allCases.map(\.systemName)).count == 36)
        #expect(Set(ProjectSymbol.allCases.map(\.displayName)).count == 36)
    }

    @Test func everySymbolResolvesToAnImageOnThisSystem() {
        for symbol in ProjectSymbol.allCases {
            #expect(NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil) != nil, "\(symbol.rawValue)")
            #expect(symbol.resolvedSystemName == symbol.systemName)
        }
        #expect(NSImage(systemSymbolName: SessionRowIcon.plainSystemName, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: SessionRowIcon.legacySystemName, accessibilityDescription: nil) != nil)
    }

    @Test func aNameTheSystemDoesNotShipIsNotResolved() {
        #expect(!ProjectSymbol.exists("not.a.real.symbol.name"))
    }

    @Test func theDefaultIsTheFolder() {
        #expect(ProjectSymbol.default == .folder)
        #expect(Project(name: "A", rootPath: "/tmp/a").symbol == .folder)
    }
}

@MainActor
struct ProjectSymbolCodingTests {
    private func decodeProject(symbolJSON: String?) throws -> Project {
        let symbolField = symbolJSON.map { #","symbol":\#($0)"# } ?? ""
        let json = #"{"id":"\#(UUID().uuidString)","name":"P","rootPath":"/tmp/p","color":2\#(symbolField),"layout":\#(layoutJSON)}"#
        return try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
    }

    private var layoutJSON: String {
        let data = try! ProjectsFile.encoder.encode(ProjectLayout.preset(.singlePane))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aNonDefaultSymbolRoundTrips() throws {
        let project = Project(name: "Board", rootPath: "/tmp/board", color: .teal, symbol: .chip)
        let data = try ProjectsFile.encoder.encode(project)
        let decoded = try ProjectsFile.decoder.decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.symbol == .chip)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["symbol"] as? String == "chip")
    }

    @Test func aMissingSymbolDecodesToTheFolder() throws {
        let project = try decodeProject(symbolJSON: nil)
        #expect(project.symbol == .folder)
        #expect(project.color == .green)
    }

    @Test func anUnknownSymbolDecodesToTheFolderAndKeepsTheProject() throws {
        let project = try decodeProject(symbolJSON: #""notARealSymbol""#)
        #expect(project.symbol == .folder)
        #expect(project.name == "P")
    }

    @Test func aNonStringSymbolDecodesToTheFolder() throws {
        #expect(try decodeProject(symbolJSON: "7").symbol == .folder)
        #expect(try decodeProject(symbolJSON: "null").symbol == .folder)
    }

    @Test func oneBadSymbolDoesNotDropANeighbouringProjectOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("batty-symbol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("projects.json")
        let good = Project(name: "Good", rootPath: "/tmp/good", symbol: .server)
        let goodJSON = String(decoding: try ProjectsFile.encoder.encode(good), as: UTF8.self)
        let badID = UUID().uuidString
        let bad = #"{"id":"\#(badID)","name":"Bad","rootPath":"/tmp/bad","symbol":"notARealSymbol","layout":\#(layoutJSON)}"#
        try Data(#"{"version":1,"projects":[\#(bad),\#(goodJSON)]}"#.utf8).write(to: url)

        let store = ProjectStore(fileURL: url)

        #expect(store.projects.map(\.name) == ["Bad", "Good"])
        #expect(store.projects.map(\.symbol) == [.folder, .server])
    }
}

@MainActor
struct ProjectSymbolTrustTests {
    @Test func changingOnlyTheSymbolKeepsTheHashAndTheApproval() {
        var project = Project(
            name: "P", rootPath: "/tmp/p", symbol: .terminal,
            layout: ProjectLayout(root: .pane(.terminal(tabs: [ProjectTab(startupCommand: "make")]))),
            runStartupCommandsOnOpen: true)
        project.approvedCommandsHash = project.startupCommandsHash
        #expect(!project.startupCommandsHash.isEmpty)
        #expect(ProjectStartupTrust.decide(project) == .runWithoutPrompt)

        let hashBefore = project.startupCommandsHash
        project.symbol = .chip

        #expect(project.startupCommandsHash == hashBefore)
        #expect(project.approvedCommandsHash == hashBefore)
        #expect(ProjectStartupTrust.decide(project) == .runWithoutPrompt)
    }
}

struct ProjectSymbolGridCursorTests {
    @Test(arguments: 0..<36, ProjectSymbolGridCursor.Direction.allCases)
    func everyTransitionClampsAndPreservesTheOtherAxis(index: Int, direction: ProjectSymbolGridCursor.Direction) {
        let row = index / 6, column = index % 6
        var expectedRow = row, expectedColumn = column
        switch direction {
        case .left: expectedColumn = max(column - 1, 0)
        case .right: expectedColumn = min(column + 1, 5)
        case .up: expectedRow = max(row - 1, 0)
        case .down: expectedRow = min(row + 1, 5)
        }
        let moved = ProjectSymbolGridCursor(index).moved(direction)
        #expect(moved.index == expectedRow * 6 + expectedColumn)
    }

    @Test func theCursorStartsOnTheSelectedSymbolAndNamesIt() {
        for symbol in ProjectSymbol.allCases {
            #expect(ProjectSymbolGridCursor(symbol).symbol == symbol)
        }
        #expect(ProjectSymbolGridCursor(ProjectSymbol.chip).index == 18)
    }

    @Test func gridShapeMatchesTheCatalog() {
        #expect(ProjectSymbolGridCursor.columns * ProjectSymbolGridCursor.rows == ProjectSymbol.allCases.count)
    }
}

struct SessionRowIconTests {
    @Test func flagOffAlwaysDrawsTheThreeColumnSymbol() {
        #expect(SessionRowIcon.systemName(flagOn: false, projectSymbol: .terminal) == "rectangle.split.3x1")
        #expect(SessionRowIcon.systemName(flagOn: false, projectSymbol: nil) == "rectangle.split.3x1")
    }

    @Test func flagOnDrawsTheCircleForAPlainSession() {
        #expect(SessionRowIcon.systemName(flagOn: true, projectSymbol: nil) == "circle.fill")
    }

    @Test func flagOnDrawsTheProjectsSymbol() {
        #expect(SessionRowIcon.systemName(flagOn: true, projectSymbol: .terminal) == "terminal.fill")
        for symbol in ProjectSymbol.allCases {
            #expect(SessionRowIcon.systemName(flagOn: true, projectSymbol: symbol) == symbol.systemName)
        }
    }
}

@MainActor
private final class SymbolFixture {
    let base: URL
    let root: URL
    let projectsFile: URL
    let cacheFile: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-symbolfx-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        projectsFile = base.appendingPathComponent("projects.json")
        cacheFile = base.appendingPathComponent("cache.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func appStore() -> AppStateStore {
        AppStateStore(
            nameCache: SessionNameCache(fileURL: cacheFile),
            featureFlags: FeatureFlags(projects: true),
            projectsFileURL: projectsFile
        )
    }

    func project(_ name: String, symbol: ProjectSymbol, color: SessionColor = .violet) -> Project {
        Project(name: name, rootPath: root.path, color: color, symbol: symbol)
    }
}

private let noContent: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = { _ in nil }

@MainActor
struct ProjectSymbolEditorTests {
    @Test func setSymbolMarksTheDraftDirtyAndRestoringItClearsIt() throws {
        let fixture = try SymbolFixture()
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let project = fixture.project("A", symbol: .chip)
        try store.upsert(project)
        let model = ProjectEditorViewModel(store: store, initialSelection: project.id)
        #expect(!model.isDirty)

        model.setSymbol(.cloud)
        #expect(model.isDirty)
        #expect(model.draft?.symbol == .cloud)

        model.setSymbol(.chip)
        #expect(!model.isDirty)
    }

    @Test func savePersistsTheSymbolAndTheListEntryCarriesIt() throws {
        let fixture = try SymbolFixture()
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let project = fixture.project("A", symbol: .chip)
        try store.upsert(project)
        let model = ProjectEditorViewModel(store: store, initialSelection: project.id)
        #expect(model.listEntries.first?.symbol == .chip)

        model.setSymbol(.game)
        #expect(model.listEntries.first?.symbol == .chip)
        let saved = try #require(model.save())

        #expect(saved.symbol == .game)
        #expect(ProjectStore(fileURL: fixture.projectsFile).project(id: project.id)?.symbol == .game)
        #expect(model.listEntries.first?.symbol == .game)
    }

    @Test func aNewDraftStartsAtTheFolderAndAnUnsavedNewRowShowsTheDraftSymbol() throws {
        let fixture = try SymbolFixture()
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let model = ProjectEditorViewModel(store: store, defaultRoot: { fixture.root.path })
        model.requestNewProject()
        #expect(model.draft?.symbol == .folder)

        model.setSymbol(.ai)
        let entry = try #require(model.listEntries.last)
        #expect(entry.isUnsavedNew)
        #expect(entry.symbol == .ai)
    }

    @Test func savingNotifiesTheSeamWithTheStoredProject() throws {
        let fixture = try SymbolFixture()
        let store = ProjectStore(fileURL: fixture.projectsFile)
        let project = fixture.project("A", symbol: .chip)
        try store.upsert(project)
        let model = ProjectEditorViewModel(store: store, initialSelection: project.id)
        var seen: [ProjectSymbol] = []
        model.projectSaved = { seen.append($0.symbol) }

        model.setSymbol(.map)
        _ = model.save()

        #expect(seen == [.map])
    }
}

@MainActor
struct ProjectSymbolSessionTests {
    @Test func openingAProjectCopiesItsSymbolOntoTheSession() throws {
        let fixture = try SymbolFixture()
        let store = fixture.appStore()
        let project = fixture.project("Board", symbol: .chip)
        try store.projectStore?.upsert(project)

        let result = try store.openProject(id: project.id, contentFactory: noContent)

        #expect(result.session.projectSymbol == .chip)
    }

    @Test func aPlainSessionHasNoProjectSymbol() throws {
        let store = try SymbolFixture().appStore()
        #expect(store.windows.flatMap(\.sessions).allSatisfy { $0.projectSymbol == nil })
    }

    @Test func savingAnEditedSymbolUpdatesEveryOpenSessionOfThatProjectAndNoOther() throws {
        let fixture = try SymbolFixture()
        let store = fixture.appStore()
        let edited = fixture.project("Edited", symbol: .chip)
        let other = fixture.project("Other", symbol: .server)
        let projectStore = try #require(store.projectStore)
        try projectStore.upsert(edited)
        try projectStore.upsert(other)

        let first = try store.openProject(id: edited.id, contentFactory: noContent).session
        let secondWindow = store.windowRuntime(for: WindowID())
        let tree = try ProjectTreeBuilder.build(project: edited, contentFactory: noContent, isSessionSelected: true)
        let second = secondWindow.addProjectSession(edited, tree: tree)
        let untouched = try store.openProject(id: other.id, contentFactory: noContent).session
        #expect(first.projectSymbol == .chip && second.projectSymbol == .chip)
        #expect(untouched.projectSymbol == .server)

        let model = ProjectEditorViewModel(store: projectStore, initialSelection: edited.id)
        model.projectSaved = { store.applyProjectSymbol(of: $0) }
        model.setSymbol(.cloud)
        #expect(first.projectSymbol == .chip)
        _ = model.save()

        #expect(first.projectSymbol == .cloud)
        #expect(second.projectSymbol == .cloud)
        #expect(untouched.projectSymbol == .server)
        #expect(first.title == "Edited")
        #expect(first.colorIndex == SessionColor.violet.rawValue)
    }

    @Test func aSymbolSaveLeavesTheSessionsTitleAndColorPinned() throws {
        let fixture = try SymbolFixture()
        let store = fixture.appStore()
        let project = fixture.project("Pinned", symbol: .chip, color: .teal)
        try store.projectStore?.upsert(project)
        let session = try store.openProject(id: project.id, contentFactory: noContent).session

        var renamed = project
        renamed.name = "Renamed"
        renamed.color = .red
        renamed.symbol = .home
        store.applyProjectSymbol(of: renamed)

        #expect(session.projectSymbol == .home)
        #expect(session.title == "Pinned")
        #expect(session.colorIndex == SessionColor.teal.rawValue)
    }
}

@MainActor
struct ProjectSymbolSurfaceTests {
    @Test func pickerCardsCarryTheSymbol() {
        let a = Project(name: "Alpha", rootPath: "/Users/test/a", symbol: .terminal)
        let b = Project(name: "Beta", rootPath: "/Users/test/b")
        let model = ProjectPickerModel(projects: [a, b], openProjectIDs: [], homeDirectory: "/Users/test")
        #expect(model.cards.map(\.symbol) == [.terminal, .folder])
    }

    @Test func fileMenuItemsCarryTheSymbol() {
        let a = Project(name: "Alpha", rootPath: "/Users/test/a", symbol: .web)
        let model = ProjectFileMenuModel.make(featureEnabled: true, projects: [a], openProjectIDs: [a.id])
        #expect(model?.items.first == .project(id: a.id, name: "Alpha", symbol: .web, isOpen: true))
    }
}

@MainActor
struct SessionRowAccessibilityValueTests {
    private func session(unseen: Int) -> SessionRuntime {
        let session = SessionRuntime(title: "S", tree: SplitTree(), colorIndex: 0)
        session.unseenBellCount = unseen
        return session
    }

    @Test func withoutAnIconTheValueIsUnchanged() {
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: true) == "selected")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: false) == "unselected")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 3), isSelected: false, iconName: nil) == "unselected, 3 unseen")
    }

    @Test func theIconNameComesLast() {
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 2), isSelected: true, iconName: "circle.fill") == "selected, 2 unseen, icon circle.fill")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: false, iconName: "cpu.fill") == "unselected, icon cpu.fill")
    }

    @Test func aProjectPartNamesTheSymbolBetweenTheBadgeAndTheIcon() {
        let plain = SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: true, projectSymbol: nil)
        #expect(plain == "selected")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: true, projectSymbol: .folder) == "selected, Project, Folder symbol")
        #expect(SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: false, projectSymbol: .terminal) == "unselected, Project, Terminal symbol")
        #expect(
            SessionSidebarView.rowAccessibilityValue(for: session(unseen: 2), isSelected: false, projectSymbol: .chip, iconName: "cpu.fill")
                == "unselected, 2 unseen, Project, \(ProjectSymbol.chip.displayName) symbol, icon cpu.fill"
        )
    }

    @Test func theProjectSymbolGate() {
        let id = UUID()
        #expect(SessionSidebarView.rowProjectSymbol(flagOn: false, projectID: id, symbol: .web) == nil)
        #expect(SessionSidebarView.rowProjectSymbol(flagOn: true, projectID: nil, symbol: .web) == nil)
        #expect(SessionSidebarView.rowProjectSymbol(flagOn: true, projectID: id, symbol: nil) == .default)
        #expect(SessionSidebarView.rowProjectSymbol(flagOn: true, projectID: id, symbol: .web) == .web)
    }

    @Test func everySymbolHasADistinctProjectPart() {
        let values = ProjectSymbol.allCases.map {
            SessionSidebarView.rowAccessibilityValue(for: session(unseen: 0), isSelected: false, projectSymbol: $0)
        }
        #expect(Set(values).count == ProjectSymbol.allCases.count)
    }

    @Test func iconsAreExposedOnlyAlongsideTheScriptVariable() {
        #expect(!UITestDriver.exposesSidebarIcons(environment: [:]))
        #expect(!UITestDriver.exposesSidebarIcons(environment: [UITestDriver.sidebarIconsEnvVar: "1"]))
        #expect(!UITestDriver.exposesSidebarIcons(environment: [UITestDriver.scriptEnvVar: "[]"]))
        #expect(UITestDriver.exposesSidebarIcons(environment: [UITestDriver.scriptEnvVar: "[]", UITestDriver.sidebarIconsEnvVar: "1"]))
    }
}
