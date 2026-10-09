// LaunchWindowGuardTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class MenuActionCounter: NSObject {
    var count = 0
    @objc func fire(_ sender: Any?) { count += 1 }
}

@MainActor
struct LaunchWindowGuardTests {
    private func makeMenu(counter: MenuActionCounter, title: String = BattyCommands.newWindowMenuTitle) -> NSMenu {
        let main = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        file.autoenablesItems = false
        let item = NSMenuItem(title: title, action: #selector(MenuActionCounter.fire(_:)), keyEquivalent: "")
        item.target = counter
        file.addItem(item)
        fileItem.submenu = file
        main.addItem(fileItem)
        return main
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    }

    @Test func performsTheNewWindowItemWhenNoContentWindowIsRegistered() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let counter = MenuActionCounter()

        let opened = LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: makeMenu(counter: counter), windows: [])

        #expect(opened)
        #expect(counter.count == 1)
    }

    @Test func doesNothingWhenAContentWindowIsRegistered() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let window = makeWindow()
        store.registerNSWindow(window, for: store.initialWindowID)
        let counter = MenuActionCounter()

        let opened = LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: makeMenu(counter: counter), windows: [])

        #expect(!opened)
        #expect(counter.count == 0)
        store.unregisterNSWindow(window)
    }

    @Test func doesNothingWhenAnUnregisteredSwiftUIContentWindowAlreadyExists() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let swiftUIWindow = makeWindow()
        swiftUIWindow.identifier = NSUserInterfaceItemIdentifier("SwiftUI.PresentedWindowContent<BattyKit.WindowID, X>-1-AppWindow-1")
        let helpLike = makeWindow()
        // Synthetic: any identifier without the SwiftUI.PresentedWindowContent prefix.
        helpLike.identifier = NSUserInterfaceItemIdentifier("help-AppWindow-1")
        let counter = MenuActionCounter()

        #expect(!LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: makeMenu(counter: counter), windows: [swiftUIWindow]))
        #expect(counter.count == 0)
        #expect(LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: makeMenu(counter: counter), windows: [helpLike]))
        #expect(counter.count == 1)
    }

    @Test func reportsFailureWhenThereIsNoNewWindowItem() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let counter = MenuActionCounter()

        #expect(!LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: makeMenu(counter: counter, title: "Something Else"), windows: []))
        #expect(!LaunchWindowGuard.openContentWindowIfMissing(store: store, mainMenu: nil, windows: []))
        #expect(counter.count == 0)
    }

    @Test func firstWindowReusesTheSeededRuntimeAndLaterWindowsGetFreshIDs() {
        let store = AppStateStore()
        store.terminateHandler = {}
        let seeded = store.initialWindowID
        #expect(store.windowIDForNewWindow() == seeded)

        let window = makeWindow()
        store.registerNSWindow(window, for: seeded)
        #expect(store.windowIDForNewWindow() != seeded)
        store.unregisterNSWindow(window)
    }
}
