// AuxiliaryWindowGateTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

/// Menu chords pressed while Settings or Help is key must not reach the
/// content window behind them. These use real, never-shown windows: the
/// classifier reads `styleMask` and `sheetParent`, which a mock would
/// only echo back.
@MainActor
struct AuxiliaryWindowGateTests {
    private func titledWindow(identifier: String? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return window
    }

    private func registeredContentWindow(in store: AppStateStore) -> NSWindow {
        let window = titledWindow()
        store.registerNSWindow(window, for: store.windows[0].id)
        return window
    }

    // MARK: - Classifier

    @Test func aRegisteredContentWindowIsNotAuxiliary() {
        let store = AppStateStore()
        let content = registeredContentWindow(in: store)
        #expect(content.styleMask.contains(.titled))
        #expect(!store.isAuxiliaryWindow(content))
    }

    @Test func anUnregisteredTitledWindowIsAuxiliary() {
        let store = AppStateStore()
        let settings = titledWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let help = titledWindow(identifier: "help")
        #expect(store.isAuxiliaryWindow(settings))
        #expect(store.isAuxiliaryWindow(help))
    }

    @Test func nonActivatingPanelsAndBorderlessWindowsAreNotAuxiliary() {
        let store = AppStateStore()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let borderless = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                                  styleMask: [], backing: .buffered, defer: true)
        borderless.isReleasedWhenClosed = false

        #expect(panel.styleMask.contains(.titled))
        #expect(!borderless.styleMask.contains(.titled))
        #expect(!store.isAuxiliaryWindow(panel))
        #expect(!store.isAuxiliaryWindow(borderless))
    }

    @Test func aSheetIsJudgedByTheWindowItHangsFrom() {
        let store = AppStateStore()
        let content = registeredContentWindow(in: store)
        let settings = titledWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let overContent = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                                  styleMask: [.titled], backing: .buffered, defer: true)
        overContent.isReleasedWhenClosed = false
        let overSettings = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        overSettings.isReleasedWhenClosed = false

        content.beginSheet(overContent)
        settings.beginSheet(overSettings)
        defer {
            content.endSheet(overContent)
            settings.endSheet(overSettings)
        }

        #expect(overContent.sheetParent === content)
        #expect(overSettings.sheetParent === settings)
        #expect(!store.isAuxiliaryWindow(overContent))
        #expect(store.isAuxiliaryWindow(overSettings))
    }

    @Test func aChildWindowIsJudgedByTheWindowItHangsFrom() {
        let store = AppStateStore()
        let content = registeredContentWindow(in: store)
        let settings = titledWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let overContent = titledWindow()
        let overSettings = titledWindow()
        content.addChildWindow(overContent, ordered: .above)
        settings.addChildWindow(overSettings, ordered: .above)
        defer {
            content.removeChildWindow(overContent)
            settings.removeChildWindow(overSettings)
        }

        #expect(overContent.parent === content)
        #expect(!store.isAuxiliaryWindow(overContent))
        #expect(store.isAuxiliaryWindow(overSettings))
    }

    @Test func nilIsNotAuxiliary() {
        #expect(!AppStateStore().isAuxiliaryWindow(nil))
    }

    /// A standalone open panel (Git Status > Change Directory...) is titled,
    /// so menu chords do not reach the terminal behind it.
    @Test func aStandaloneOpenPanelIsAuxiliary() {
        let panel = NSOpenPanel()
        #expect(AppStateStore().isAuxiliaryWindow(panel))
    }

    @Test func aTitledPanelThatIsNotNonActivatingIsAuxiliary() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        #expect(AppStateStore().isAuxiliaryWindow(panel))
    }

    @Test func theRegistryDecidesNotTheWindowsIdentifier() {
        let store = AppStateStore()
        let window = titledWindow(identifier: "com_apple_SwiftUI_Settings_window")
        #expect(store.isAuxiliaryWindow(window))
        store.registerNSWindow(window, for: store.windows[0].id)
        #expect(!store.isAuxiliaryWindow(window))
        store.unregisterNSWindow(window)
    }

    // MARK: - Key-window state

    @Test func auxiliaryWindowIsKeyReadsTheKeyWindowProvider() {
        let store = AppStateStore()
        let settings = titledWindow()
        let content = registeredContentWindow(in: store)

        store.keyWindowProvider = { settings }
        #expect(store.auxiliaryWindowIsKey)
        store.keyWindowProvider = { content }
        #expect(!store.auxiliaryWindowIsKey)
        store.keyWindowProvider = { nil }
        #expect(!store.auxiliaryWindowIsKey)
    }

    // MARK: - Menu target

    @Test func menuTargetIsNilOnlyWhileAnAuxiliaryWindowIsKey() {
        let store = AppStateStore()
        let content = store.windows[0]
        #expect(store.menuTargetWindow(auxiliaryWindowIsKey: false)?.id == content.id)
        #expect(store.menuTargetWindow(auxiliaryWindowIsKey: true) == nil)
    }

    @Test func enablementAndCLIResolutionIgnoreTheAuxiliaryKeyState() {
        let store = AppStateStore()
        let content = store.windows[0]
        store.keyWindowProvider = { self.titledWindow() }
        #expect(store.auxiliaryWindowIsKey)

        #expect(store.menuTargetWindow() == nil)
        #expect(store.keyWindowOrFirstRegistered()?.id == content.id)
        #expect(store.defaultTargetWindow()?.id == content.id)
        #expect(store.focusedSessionIDFallback() == content.selectedSession?.id)
    }

    @Test func menuTargetComesBackWhenAContentWindowIsKeyAgain() {
        let store = AppStateStore()
        let content = store.windows[0]
        let contentWindow = registeredContentWindow(in: store)
        let settings = titledWindow()

        store.keyWindowProvider = { settings }
        #expect(store.menuTargetWindow() == nil)
        store.keyWindowProvider = { contentWindow }
        #expect(store.menuTargetWindow()?.id == content.id)
    }

    @Test func theFocusedTerminalTabIsNilWhileAnAuxiliaryWindowIsKey() {
        let store = AppStateStore()
        let expected = store.windows[0].selectedSession?.focusedTerminalPane?.activeTab
        #expect(expected != nil)

        #expect(store.focusedTerminalTab(auxiliaryWindowIsKey: false)?.id == expected?.id)
        #expect(store.focusedTerminalTab(auxiliaryWindowIsKey: true) == nil)
    }

    // MARK: - Dispatchers

    @Test func exitShellSendsNothingWhileAnAuxiliaryWindowIsKey() {
        let store = AppStateStore()
        let saved = ExitDispatcher.sendText
        defer { ExitDispatcher.sendText = saved }
        var sent: [String] = []
        ExitDispatcher.sendText = { _, text in sent.append(text) }

        ExitDispatcher.sendExit(store: store)
        #expect(sent == ["exit\n"], "baseline: with no auxiliary window key the shell is sent exit")

        sent.removeAll()
        store.keyWindowProvider = { self.titledWindow() }
        ExitDispatcher.sendExit(store: store)
        #expect(sent.isEmpty)
    }

    @Test func pasteGoesToTheStandardActionAndNeverToTheTerminalWhileAnAuxiliaryWindowIsKey() {
        let testDefaults = TestDefaults()
        defer { testDefaults.tearDown() }
        testDefaults.defaults.set(PasteStrictness.alwaysOnMultiline.rawValue, forKey: SettingsPreference.pasteStrictnessKey)
        let store = AppStateStore(preferences: testDefaults.defaults)

        let savedPasteboard = NSPasteboard.general.string(forType: .string)
        let savedForwardStandardPaste = PasteDispatcher.forwardStandardPaste
        defer {
            NSPasteboard.general.clearContents()
            if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) }
            PasteDispatcher.forwardStandardPaste = savedForwardStandardPaste
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("line one\nline two\n", forType: .string)

        var posted = 0
        let observer = NotificationCenter.default.addObserver(forName: .battyRequestPaste, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var forwarded = 0
        PasteDispatcher.forwardStandardPaste = { forwarded += 1 }

        PasteDispatcher.handlePasteRequest(store: store)
        #expect(posted == 1 && forwarded == 0, "baseline: a content window key requests the paste confirmation")

        posted = 0
        store.keyWindowProvider = { self.titledWindow() }
        PasteDispatcher.handlePasteRequest(store: store)
        #expect(posted == 0, "the paste must not be requested for the terminal behind Settings")
        #expect(forwarded == 1, "the standard paste action must run so a focused Settings text field still pastes")
    }
}
