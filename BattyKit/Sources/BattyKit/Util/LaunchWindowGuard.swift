// LaunchWindowGuard.swift

import AppKit
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "LaunchWindowGuard")

/// Guarantees a launch ends with a content window.
///
/// AppKit can record a launch as "state restored" without restoring any
/// window, and SwiftUI then skips the `WindowGroup`'s default window: the app
/// runs with a menu bar and nothing else (#0444). While no window exists the
/// scene's `openWindow` action is reachable only through the "New Window"
/// menu item, so that is what the guard performs. The item presents
/// `AppStateStore.windowIDForNewWindow()`, which is the seeded
/// `initialWindowID` while nothing is registered, so no phantom runtime is
/// created (#0251) and an already-open window is focused instead of
/// duplicated.
@MainActor
public enum LaunchWindowGuard {
    /// Runs `check` once, the first time the main run loop is about to wait.
    ///
    /// That SwiftUI's own default window exists by then is an observation, not
    /// an API guarantee: in the full UI run `20261006-033829-79840` the guard
    /// fired on exactly the 25 launches that had no window and on none of the
    /// ~50 normal launches. The observer is added at the latest order so it
    /// runs after any other `beforeWaiting` work, and `check` also treats an
    /// existing SwiftUI window as present (`hasContentWindow`) so a late
    /// default window cannot be doubled.
    public static func installAtFirstQuiescence(_ check: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { obs, _ in
            if let obs { CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes) }
            MainActor.assumeIsolated { check() }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    /// True when `windows` holds a SwiftUI content window that is not yet in
    /// the store's registry (registration happens in `viewDidMoveToWindow`, so
    /// a window can briefly exist without being registered).
    static func hasContentWindow(in windows: [NSWindow]) -> Bool {
        windows.contains { $0.identifier?.rawValue.hasPrefix("SwiftUI.PresentedWindowContent") == true }
    }

    /// Opens the first content window when the launch produced none. Returns
    /// whether it triggered an open.
    @discardableResult
    public static func openContentWindowIfMissing(
        store: AppStateStore,
        mainMenu: NSMenu? = NSApp.mainMenu,
        windows: [NSWindow] = NSApp.windows
    ) -> Bool {
        guard store.launchNeedsContentWindow, !hasContentWindow(in: windows) else { return false }
        let title = BattyCommands.newWindowMenuTitle
        guard let mainMenu, let (menu, index) = findMenuItem(titled: title, in: mainMenu) else {
            logger.error("launch produced no content window and no \(title, privacy: .public) menu item was found to open one")
            return false
        }
        logger.info("launch produced no content window; opening one via the \(title, privacy: .public) menu item")
        menu.performActionForItem(at: index)
        return true
    }

    static func findMenuItem(titled title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title, item.action != nil { return (menu, index) }
            if let submenu = item.submenu, let found = findMenuItem(titled: title, in: submenu) {
                return found
            }
        }
        return nil
    }
}
