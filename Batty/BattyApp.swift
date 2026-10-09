// BattyApp.swift

import AppKit
import BattyKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: Logging.subsystem, category: "BattyApp")

// No `@main` here — `main.swift` owns the entry point so the #0364
// argv[0] guard runs before any SwiftUI/AppKit machinery, not just before
// this struct's `body`. `BattyApp.main()` (the `App` protocol's default
// implementation) is still what `main.swift` calls into once the guard
// passes.
struct BattyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: BattyAppDelegate

    var body: some Scene {
        WindowGroup(for: WindowID.self) { $windowID in
            ContentView(windowID: windowID)
                .background(OpenWindowHookInstaller())
        } defaultValue: {
            // Return the WindowID already seeded in AppStateStore.shared.windows[0]
            // so that SwiftUI's first content window reuses the existing runtime
            // rather than creating a phantom second one. A phantom second runtime
            // causes batty <path> sessions to land in windows[0] (the phantom)
            // while the visible window shows an empty windows[1] — #0251.
            AppStateStore.shared.initialWindowID
        }
        // Suppress SwiftUI's default behavior of opening a new window for
        // external URL events (batty://). Without this, the OS delivers the
        // URL to both NSApplicationDelegate.application(_:open:) (correct —
        // our handler adds the session to the active window) AND to SwiftUI's
        // scene machinery, which spawns an extra empty window. Passing an empty
        // set means this scene does not volunteer to match any external event
        // by activity/URL type — it won't be selected as a target for a new
        // scene, so no extra window opens. Cmd-N and openWindow(value:) are
        // internal SwiftUI actions and are unaffected by handlesExternalEvents
        // — only OS-delivered URL opens are suppressed. (#0251 second root cause)
        .handlesExternalEvents(matching: Set())
        // Batty deliberately does not restore its window set (user decision
        // 2026-10-09). That gives up #0238's window-count, display and
        // @SceneStorage restoration; whether the first window's frame is still
        // remembered by AppKit's own autosave is unverified. It is kept off so that a restored window
        // carrying a stale WindowID cannot appear next to the runtime
        // AppStateStore.init seeded, now that the saved identifier no longer
        // changes every launch. It is NOT what fixes #0444: the missing launch
        // window is guaranteed by LaunchWindowGuard.
        .restorationBehavior(.disabled)
        .commandsRemoved()
        .commands {
            BattyCommands()
        }

        Window("Batty Help", id: "help") {
            HelpView()
        }
        // Also decline external URL events here. When the content WindowGroup
        // above stops volunteering for batty:// opens, SwiftUI otherwise falls
        // back to the next scene that *does* accept external events — this Help
        // window — and opens it. Declining here too means no scene volunteers,
        // so the OS-delivered URL is handled only by application(_:open:) and no
        // stray window (content or Help) appears. Opening Help via the menu uses
        // the internal openWindow(id: "help") action, which is unaffected. (#0251)
        .handlesExternalEvents(matching: Set())
        // Precaution, not verified to matter: keeps the Help window out of
        // restored state for the same reason as the content scene above.
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(\.appStateStore, AppStateStore.shared)
        }
    }
}

final class BattyAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var appearanceObserver: AppearanceObserver?
    private let xpcCoordinator = AppXPCCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            BattyShortcuts.handle(event) ? nil : event
        }
        TerminalClickFocusMonitor.start()
        appearanceObserver = AppearanceObserver(store: AppStateStore.shared)
        AppStateStore.shared.nameSuggester = FoundationModelsNameSuggester.makeIfAvailable()
        AppStateStore.shared.notificationSummarizer = FoundationModelsNotificationSummarizer.makeIfAvailable()
        AppStateStore.shared.footprintMonitor.start()
        TerminalHostStore.shared.startOccludedSurfaceTicking()
        TerminalMetalMetricsLogger.startIfEnabled()
        // onAllSessionsClosed is wired per-window in AppStateStore.init and
        // windowRuntime(for:) — each window's closure closes itself when its
        // last session goes. The app terminates when the last content window
        // is unregistered (AppStateStore.unregisterNSWindow →
        // terminateIfLastContentWindowGone). No app-level terminate hook here.
        xpcCoordinator.start()
        LaunchWindowGuard.installAtFirstQuiescence {
            LaunchWindowGuard.openContentWindowIfMissing(store: AppStateStore.shared)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let store = AppStateStore.shared
        let registeredWindowCount = store.registeredContentWindowCount
        logger.info("application(_:open:) urls=\(urls.map(\.absoluteString).joined(separator: ", "), privacy: .public) registeredContentWindows=\(registeredWindowCount, privacy: .public)")
        for url in urls where url.scheme == "batty" {
            BattyURLHandler.handle(url, store: store)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppStateStore.shared
        let totalTabs = store.windows.reduce(0) { acc, w in
            acc + w.sessions.flatMap { $0.tree.allPanes }.flatMap { $0.tabs }.count
        }
        logger.info("applicationShouldTerminate windows=\(store.windows.count, privacy: .public) totalTabs=\(totalTabs, privacy: .public)")
        if QuitConfirmation.shouldQuitOrPrompt(store: store) {
            store.nameCache.save()
            logger.info("applicationShouldTerminate -> terminateNow")
            return .terminateNow
        }
        logger.info("applicationShouldTerminate -> terminateCancel (prompt shown)")
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Runs only on the path that actually quits (after
        // applicationShouldTerminate returns .terminateNow, or a system
        // -initiated quit) — tells any attached CLI before the connection
        // just drops out from under it (#0272 item 4).
        xpcCoordinator.prepareForTermination()
        // Non-terminal pane content (#0303/#0314): review round 1 found no
        // path tore this down on quit either — a system-metrics pane's
        // sampling Task, or #0313's own child-process-owning conformer,
        // would otherwise be abandoned to process teardown rather than
        // torn down deterministically. The OS reclaims the Task/process
        // either way on exit, but relying on that instead of an explicit,
        // observable teardown is exactly what
        // `docs/pane-view-lifecycle.md` §5 argues against.
        // `...SynchronouslyForQuit` (not the plain `tearDownAllPaneContent()`
        // other callers use): #0354/#0422 moved subprocess-teardown's
        // bounded wait off the main actor onto a detached task so an
        // ordinary pane close stays responsive, but a detached task
        // scheduled here may never run — the app process exits shortly
        // after this method returns. This variant waits synchronously for
        // any conformer that needs it (`DeferredTeardownWaiting`), which is
        // an acceptable brief block only because the app is already
        // quitting.
        for window in AppStateStore.shared.windows {
            window.tearDownAllPaneContentSynchronouslyForQuit()
        }
        // #0425: the walk above only reaches a reap whose owning pane is
        // still in `AppStateStore.windows` at this point. A pane, tab,
        // session, or window closed moments before quit already left that
        // tree, so its `SIGTERM`-ignoring child's reap was reachable only by
        // racing process exit against the detached task `tearDown()`
        // scheduled for it. `PendingTeardownReapRegistry` is independent of
        // the model tree — draining it here catches that reap regardless.
        PendingTeardownReapRegistry.shared.drainSynchronously()
    }
}

/// Wires the SwiftUI `openWindow` action into `AppStateStore` so the
/// NSEvent-monitor path (`BattyShortcuts`) can open new windows without an
/// `@Environment` reference. Placed in the content scene's view tree so the
/// action is always live while any content window exists.
struct OpenWindowHookInstaller: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                AppStateStore.shared.openWindowAction = {
                    logger.info("openWindowAction: opening new content window")
                    openWindow(value: AppStateStore.shared.windowIDForNewWindow())
                }
            }
    }
}
