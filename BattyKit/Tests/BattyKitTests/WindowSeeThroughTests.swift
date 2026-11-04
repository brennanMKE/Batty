// WindowSeeThroughTests.swift

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BattyKit

private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class WindowSeeThroughTests {
    private static let low = TerminalBackgroundSettings(imagePath: nil, terminalOpacity: 0.4)
    private static let full = TerminalBackgroundSettings(imagePath: nil, fit: .cover, terminalOpacity: 1)
    private static let theme = Color.red
    private static let systemWindow = Color(nsColor: .windowBackgroundColor)

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    private func makeStore(sessions: [SessionRuntime]? = nil) -> AppStateStore {
        AppStateStore(
            sessions: sessions ?? [session()],
            preferences: defaults,
            backgroundGate: .acceptingEveryImage(defaults: defaults)
        )
    }

    private func pane() -> PaneRuntime {
        PaneRuntime(tabBackgroundGate: .acceptingEveryImage(defaults: defaults))
    }

    private func session(_ pane: PaneRuntime? = nil) -> SessionRuntime {
        SessionRuntime(tree: SplitTree(root: .leaf(pane ?? self.pane())))
    }

    private func firstWindow(_ store: AppStateStore) throws -> WindowRuntime {
        try #require(store.windows.first)
    }

    private func storeAppWide(_ opacity: Double) {
        defaults.set(opacity, forKey: SettingsPreference.backgroundOpacityKey)
    }

    // MARK: - Derivation

    @Test func everyPaneAtFullOpacityIsNotSeeThrough() throws {
        let store = makeStore()
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func appWideBelowOneMakesAFollowingWindowSeeThrough() throws {
        storeAppWide(0.5)
        let store = makeStore()
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func paneOverrideBelowOneMakesTheWindowSeeThrough() throws {
        let pane = pane()
        let store = makeStore(sessions: [session(pane)])
        pane.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func paneOverrideAtOneWithAppWideBelowOneIsNotSeeThrough() throws {
        storeAppWide(0.5)
        let pane = pane()
        let store = makeStore(sessions: [session(pane)])
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        pane.setBackgroundOverride(Self.full)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func oneLowPaneAmongOpaquePanesIsSeeThrough() throws {
        let first = pane()
        let session = session(first)
        _ = session.tree.splitFocusedPane(direction: .horizontal)
        let store = makeStore(sessions: [session])
        #expect(session.tree.allPanes.count == 2)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
        first.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func nonTerminalPaneIsIgnored() throws {
        storeAppWide(0.5)
        let metrics = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in nil })
        let store = makeStore(sessions: [session(metrics)])
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func paneInAnUnselectedSessionCounts() throws {
        let low = pane()
        let unselected = session(low)
        let selected = session()
        let store = makeStore(sessions: [unselected, selected])
        let window = try firstWindow(store)
        window.setSelectedSession(id: selected.id)
        #expect(!store.isWindowSeeThrough(window))
        low.setBackgroundOverride(Self.low)
        #expect(window.selectedSessionID == selected.id)
        #expect(store.isWindowSeeThrough(window))
    }

    @Test func hiddenPaneCounts() throws {
        let low = pane()
        let session = session(low)
        _ = session.tree.splitFocusedPane(direction: .horizontal)
        let store = makeStore(sessions: [session])
        low.setBackgroundOverride(Self.low)
        store.hidePane(id: low.id)
        #expect(low.isHidden)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func closingTheLastLowPaneEndsSeeThrough() throws {
        let low = pane()
        let session = session(low)
        _ = session.tree.splitFocusedPane(direction: .horizontal)
        let store = makeStore(sessions: [session])
        low.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        #expect(store.closePane(id: low.id) == .closed)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func returningToFollowEndsSeeThrough() throws {
        let pane = pane()
        let store = makeStore(sessions: [session(pane)])
        pane.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        pane.setBackgroundOverride(nil)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    // MARK: - Session override

    @Test func sessionOverrideBelowOneMakesTheWindowSeeThrough() throws {
        let session = session()
        let store = makeStore(sessions: [session])
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
        session.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func sessionOverrideAtOneWithAppWideBelowOneIsNotSeeThrough() throws {
        storeAppWide(0.5)
        let session = session()
        let store = makeStore(sessions: [session])
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        session.setBackgroundOverride(Self.full)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func sessionOverrideInAnUnselectedSessionCounts() throws {
        let unselected = session()
        let selected = session()
        let store = makeStore(sessions: [unselected, selected])
        let window = try firstWindow(store)
        window.setSelectedSession(id: selected.id)
        #expect(!store.isWindowSeeThrough(window))
        unselected.setBackgroundOverride(Self.low)
        #expect(window.selectedSessionID == selected.id)
        #expect(store.isWindowSeeThrough(window))
    }

    @Test func paneOverrideAtOneInALowSessionIsNotSeeThrough() throws {
        let pane = pane()
        let session = session(pane)
        let store = makeStore(sessions: [session])
        session.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        pane.setBackgroundOverride(Self.full)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func paneOverrideBelowOneInAFullSessionIsSeeThrough() throws {
        let pane = pane()
        let session = session(pane)
        let store = makeStore(sessions: [session])
        session.setBackgroundOverride(Self.full)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
        pane.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func clearingTheSessionOverrideEndsSeeThrough() throws {
        let session = session()
        let store = makeStore(sessions: [session])
        session.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        session.setBackgroundOverride(nil)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func sessionWithOnlyNonTerminalPanesIsIgnored() throws {
        let metrics = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in nil })
        let session = session(metrics)
        let store = makeStore(sessions: [session])
        session.setBackgroundOverride(Self.low)
        #expect(session.backgroundOverride == Self.low)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func sessionOverrideInvalidatesAnObservedSeeThroughRead() throws {
        let session = session()
        let store = makeStore(sessions: [session])
        let window = try firstWindow(store)
        let changed = ChangeFlag()
        withObservationTracking { _ = store.isWindowSeeThrough(window) } onChange: { changed.fired = true }
        session.setBackgroundOverride(Self.low)
        #expect(changed.fired)
    }

    @Test func nativeFullScreenForcesOpaque() throws {
        storeAppWide(0.5)
        let store = makeStore()
        let window = try firstWindow(store)
        #expect(store.isWindowSeeThrough(window))
        window.setNativeFullScreen(true)
        #expect(!store.isWindowSeeThrough(window))
        window.setNativeFullScreen(false)
        #expect(store.isWindowSeeThrough(window))
    }

    @Test func windowsAreIndependent() throws {
        let low = pane()
        let store = makeStore(sessions: [session(low)])
        let other = store.windowRuntime(for: WindowID())
        if other.sessions.isEmpty { other.addSession() }
        low.setBackgroundOverride(Self.low)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        #expect(!store.isWindowSeeThrough(other))
    }

    @Test func windowOpenedLaterFollowsTheAppWideValue() {
        storeAppWide(0.5)
        let store = makeStore()
        let later = store.windowRuntime(for: WindowID())
        if later.sessions.isEmpty { later.addSession() }
        #expect(store.isWindowSeeThrough(later))
    }

    @Test func appWideOpacityIsSeededFromTheStoredValue() {
        storeAppWide(0.3)
        #expect(makeStore().appWideTerminalOpacity == 0.3)
    }

    @Test func appWideChangeUpdatesTheObservedOpacity() throws {
        let store = makeStore()
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
        let changed = ChangeFlag()
        withObservationTracking { _ = store.appWideTerminalOpacity } onChange: { changed.fired = true }
        AppWideBackgroundEditor(store: store).update { _ in Self.low }
        #expect(changed.fired)
        #expect(store.appWideTerminalOpacity == 0.4)
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func restoreDefaultsEndsSeeThrough() throws {
        storeAppWide(0.5)
        let store = makeStore()
        #expect(store.isWindowSeeThrough(try firstWindow(store)))
        AppWideBackgroundEditor(store: store).reset()
        #expect(store.appWideTerminalOpacity == 1)
        #expect(!store.isWindowSeeThrough(try firstWindow(store)))
    }

    @Test func equalAppWideOpacityDoesNotNotify() {
        storeAppWide(0.5)
        let store = makeStore()
        let changed = ChangeFlag()
        withObservationTracking { _ = store.appWideTerminalOpacity } onChange: { changed.fired = true }
        store.applyAppWideBackgroundToAllSurfaces()
        #expect(!changed.fired)
        storeAppWide(0.6)
        store.applyAppWideBackgroundToAllSurfaces()
        #expect(changed.fired)
    }

    @Test func setNativeFullScreenIsIdempotent() throws {
        let window = try firstWindow(makeStore())
        window.setNativeFullScreen(true)
        let changed = ChangeFlag()
        withObservationTracking { _ = window.isNativeFullScreen } onChange: { changed.fired = true }
        window.setNativeFullScreen(true)
        #expect(!changed.fired)
        window.setNativeFullScreen(false)
        #expect(changed.fired)
    }

    @Test func opacityChangeKeepsTheSameController() throws {
        let pane = pane()
        let store = makeStore(sessions: [session(pane)])
        let tab = try #require(pane.tabs.first)
        let controller = tab.terminal.controller
        AppWideBackgroundEditor(store: store).update { _ in Self.low }
        #expect(tab.terminal.renderedConfig.contains("background-opacity = 0.4"))
        #expect(tab.terminal.controller === controller)
    }

    // MARK: - Delegate

    @Test func fullScreenCallbacksUpdateTheRuntime() throws {
        let store = makeStore()
        let window = try firstWindow(store)
        let delegate = WindowDelegate(windowID: window.id, store: store)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(window.isNativeFullScreen)
        delegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        #expect(!window.isNativeFullScreen)
    }

    @Test func failedFullScreenEntryRestoresTheRuntime() throws {
        let store = makeStore()
        let window = try firstWindow(store)
        let delegate = WindowDelegate(windowID: window.id, store: store)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(window.isNativeFullScreen)
        delegate.windowDidFailToEnterFullScreen(unshownWindow())
        #expect(!window.isNativeFullScreen)
    }

    @Test func fullScreenCallbackAfterWindowRemovalCreatesNoRuntime() throws {
        let store = makeStore()
        let kept = try firstWindow(store)
        let removed = store.windowRuntime(for: WindowID())
        let delegate = WindowDelegate(windowID: removed.id, store: store)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(removed.isNativeFullScreen)

        store.removeWindow(id: removed.id)
        delegate.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        #expect(store.windows.map(\.id) == [kept.id])
        delegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        #expect(store.windows.map(\.id) == [kept.id])
        delegate.windowDidFailToEnterFullScreen(unshownWindow())
        #expect(store.windows.map(\.id) == [kept.id])
    }

    // MARK: - Fills

    @Test func backdropIsTodaysValueWhenNotSeeThrough() {
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: false, hasSelectedSession: true, windowBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: false, hasSelectedSession: false, windowBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: false, hasSelectedSession: true, windowBackground: nil) == .clear)
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: false, hasSelectedSession: false, windowBackground: nil) == .clear)
    }

    @Test func backdropIsClearWhenSeeThroughWithASession() {
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: true, hasSelectedSession: true, windowBackground: Self.theme) == .clear)
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: true, hasSelectedSession: true, windowBackground: nil) == .clear)
    }

    @Test func backdropIsPaintedWhenSeeThroughWithNoSession() {
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: true, hasSelectedSession: false, windowBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.backdropFill(isSeeThrough: true, hasSelectedSession: false, windowBackground: nil) == Self.systemWindow)
    }

    @Test func titlebarFillIsTheThemeColorOnlyWhenSeeThrough() {
        #expect(WindowSeeThrough.titlebarFill(isSeeThrough: true, windowBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.titlebarFill(isSeeThrough: false, windowBackground: Self.theme) == .clear)
        #expect(WindowSeeThrough.titlebarFill(isSeeThrough: true, windowBackground: nil) == .clear)
        #expect(WindowSeeThrough.titlebarFill(isSeeThrough: false, windowBackground: nil) == .clear)
    }

    @Test func chromeBackingIsClearWhenNotSeeThrough() {
        #expect(WindowSeeThrough.chromeBacking(isSeeThrough: false, windowBackground: Self.theme) == .clear)
        #expect(WindowSeeThrough.chromeBacking(isSeeThrough: false, windowBackground: nil) == .clear)
    }

    @Test func chromeBackingPrefersTheThemeColor() {
        #expect(WindowSeeThrough.chromeBacking(isSeeThrough: true, windowBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.chromeBacking(isSeeThrough: true, windowBackground: nil) == Self.systemWindow)
    }

    @Test func sidebarFillIsNilWithNoThemeAndNoSeeThrough() {
        #expect(WindowSeeThrough.sidebarFill(isSeeThrough: false, chromeBackground: nil) == nil)
        #expect(WindowSeeThrough.sidebarFill(isSeeThrough: true, chromeBackground: nil) == Self.systemWindow)
    }

    @Test func sidebarFillIsTheThemeColorEitherWay() {
        #expect(WindowSeeThrough.sidebarFill(isSeeThrough: false, chromeBackground: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.sidebarFill(isSeeThrough: true, chromeBackground: Self.theme) == Self.theme)
    }

    @Test func sidebarSelectionTintIsNilWithNoThemeAndNoSeeThrough() {
        #expect(WindowSeeThrough.sidebarSelectionTint(isSeeThrough: false, themeTint: nil) == nil)
    }

    @Test func sidebarSelectionTintIsPaintedWithNoThemeWhenSeeThrough() {
        #expect(WindowSeeThrough.sidebarSelectionTint(isSeeThrough: true, themeTint: nil) != nil)
    }

    @Test func sidebarSelectionTintIsTheThemeTintEitherWay() {
        #expect(WindowSeeThrough.sidebarSelectionTint(isSeeThrough: false, themeTint: Self.theme) == Self.theme)
        #expect(WindowSeeThrough.sidebarSelectionTint(isSeeThrough: true, themeTint: Self.theme) == Self.theme)
    }

    // MARK: - Window

    private func unshownWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private var themedPalette: ChromePalette {
        get throws {
            let theme = try #require(BattyThemeCatalog.allThemes.first)
            return ChromePalette(theme: theme)
        }
    }

    @Test func opaqueApplyWithNoThemeLeavesAFreshWindowsValues() {
        let fresh = unshownWindow()
        let window = unshownWindow()
        WindowSeeThrough.apply(palette: ChromePalette(theme: nil), isSeeThrough: false, to: window)
        #expect(window.isOpaque == fresh.isOpaque)
        #expect(window.backgroundColor == fresh.backgroundColor)
        #expect(window.titlebarAppearsTransparent == fresh.titlebarAppearsTransparent)
        #expect(window.ignoresMouseEvents == fresh.ignoresMouseEvents)
    }

    @Test func opaqueApplyWithAThemePaintsTheThemeColor() throws {
        let palette = try themedPalette
        let window = unshownWindow()
        WindowSeeThrough.apply(palette: palette, isSeeThrough: false, to: window)
        #expect(window.isOpaque)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.backgroundColor == NSColor(try #require(palette.windowBackground)))
    }

    @Test func seeThroughApplyMakesTheWindowNonOpaque() throws {
        for palette in [ChromePalette(theme: nil), try themedPalette] {
            let window = unshownWindow()
            WindowSeeThrough.apply(palette: palette, isSeeThrough: true, to: window)
            #expect(!window.isOpaque)
            #expect(window.backgroundColor == WindowSeeThrough.windowColor)
            #expect(!window.ignoresMouseEvents)
        }
    }

    @Test func windowColorKeepsAlphaAboveZeroAfterRounding() {
        #expect((WindowSeeThrough.windowColor.alphaComponent * 255).rounded() >= 1)
    }

    @Test func seeThroughThenOpaqueRestoresTheWindow() throws {
        let palette = try themedPalette
        let themedTarget = unshownWindow()
        WindowSeeThrough.apply(palette: palette, isSeeThrough: false, to: themedTarget)

        let themed = unshownWindow()
        WindowSeeThrough.apply(palette: palette, isSeeThrough: true, to: themed)
        WindowSeeThrough.apply(palette: palette, isSeeThrough: false, to: themed)
        #expect(themed.isOpaque)
        #expect(themed.backgroundColor == themedTarget.backgroundColor)

        let fresh = unshownWindow()
        let plain = unshownWindow()
        WindowSeeThrough.apply(palette: ChromePalette(theme: nil), isSeeThrough: true, to: plain)
        #expect(plain.backgroundColor != fresh.backgroundColor)
        WindowSeeThrough.apply(palette: ChromePalette(theme: nil), isSeeThrough: false, to: plain)
        #expect(plain.isOpaque)
        #expect(plain.backgroundColor == fresh.backgroundColor)
    }

    @Test func titlebarTransparencyFollowsTheThemeInBothStates() throws {
        let palette = try themedPalette
        for isSeeThrough in [true, false] {
            let themed = unshownWindow()
            WindowSeeThrough.apply(palette: palette, isSeeThrough: isSeeThrough, to: themed)
            #expect(themed.titlebarAppearsTransparent)

            let plain = unshownWindow()
            plain.titlebarAppearsTransparent = true
            WindowSeeThrough.apply(palette: ChromePalette(theme: nil), isSeeThrough: isSeeThrough, to: plain)
            #expect(!plain.titlebarAppearsTransparent)
        }
    }

    // MARK: - A user who configured nothing

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-see-through-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func emptyDefaultsResolveToNoBackgroundAndAnOpaqueWindow() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AppWideBackgroundGate.make(defaults: defaults, directory: root.appendingPathComponent("TerminalBackgrounds"))
        #expect(gate.settings() == .off)
        #expect(gate.storedSettings() == .off)
        #expect(gate.refreshImageState() == .none)

        let pane = PaneRuntime(tabBackgroundGate: gate)
        let store = AppStateStore(sessions: [session(pane)], preferences: defaults, backgroundGate: gate)
        let window = try firstWindow(store)
        let backgroundLines = { pane.tabs[0].terminal.renderedConfig.split(separator: "\n").filter { $0.hasPrefix("background-") } }
        #expect(store.appWideTerminalOpacity == 1)
        #expect(!store.isWindowSeeThrough(window))
        #expect(backgroundLines().isEmpty)

        // The control: the same store and Tab do respond to a stored value.
        storeAppWide(0.5)
        store.applyAppWideBackgroundToAllSurfaces()
        #expect(store.isWindowSeeThrough(window))
        #expect(backgroundLines().contains("background-opacity = 0.5"))
    }

    @Test func emptyDefaultsCreateNoBackgroundFolders() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gateDirectory = root.appendingPathComponent("TerminalBackgrounds", isDirectory: true)
        let projectsFile = root.appendingPathComponent("projects.json")
        let gate = AppWideBackgroundGate.make(defaults: defaults, directory: gateDirectory)
        let store = AppStateStore(
            sessions: [SessionRuntime(tree: SplitTree(root: .leaf(PaneRuntime(tabBackgroundGate: gate))))],
            nameCache: SessionNameCache(fileURL: root.appendingPathComponent("cache.json")),
            preferences: defaults,
            projectsFileURL: projectsFile,
            backgroundGate: gate
        )
        store.applyAppearanceToAllSurfaces()
        store.applyAppWideBackgroundToAllSurfaces()

        let files = FileManager.default
        #expect(!files.fileExists(atPath: gateDirectory.path))
        #expect(!files.fileExists(atPath: store.projectBackgrounds.directory.path))
        #expect(!files.fileExists(atPath: projectsFile.path))
    }

    @Test func emptyDefaultsWindowKeepsAFreshWindowsValues() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AppWideBackgroundGate.make(defaults: defaults, directory: root.appendingPathComponent("TerminalBackgrounds"))
        let store = AppStateStore(
            sessions: [SessionRuntime(tree: SplitTree(root: .leaf(PaneRuntime(tabBackgroundGate: gate))))],
            preferences: defaults,
            backgroundGate: gate
        )
        let fresh = unshownWindow()
        let window = unshownWindow()
        WindowSeeThrough.apply(
            palette: ChromePalette(theme: nil),
            isSeeThrough: store.isWindowSeeThrough(try firstWindow(store)),
            to: window
        )
        #expect(window.isOpaque)
        #expect(window.isOpaque == fresh.isOpaque)
        #expect(window.backgroundColor == fresh.backgroundColor)
        #expect(window.titlebarAppearsTransparent == fresh.titlebarAppearsTransparent)
    }
}
