// SessionDetailFixture.swift

import AppKit
import SwiftUI
@testable import BattyKit

/// The production `NavigationSplitView { SessionSidebarView } detail:
/// { SessionDetailView }` shape, hosted in a `LayoutConvergenceProbe` by
/// the Session detail layout suites.
struct SessionDetailTestTree: View {
    let store: AppStateStore
    let windowRuntime: WindowRuntime

    var body: some View {
        NavigationSplitView {
            SessionSidebarView(store: store, windowRuntime: windowRuntime)
        } detail: {
            SessionDetailView(store: store, windowRuntime: windowRuntime)
        }
        .environment(\.appStateStore, store)
        .environment(\.themeChrome, store.themeChrome)
    }
}

@MainActor
struct SessionDetailFixture {
    static let titledStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let probe: LayoutConvergenceProbe
    var testDefaults: TestDefaults?

    /// Hosts `windowRuntime` (the first window of `store`) after `arrange`
    /// has built its Sessions.
    init(
        store: AppStateStore,
        size: CGSize = CGSize(width: 1100, height: 700),
        arrange: (AppStateStore, WindowRuntime) -> Void
    ) {
        let windowRuntime = store.windows[0]
        arrange(store, windowRuntime)
        self.store = store
        self.windowRuntime = windowRuntime
        self.probe = LayoutConvergenceProbe(
            SessionDetailTestTree(store: store, windowRuntime: windowRuntime),
            size: size,
            styleMask: Self.titledStyle
        )
    }

    /// As in production, every Session stays mounted (non-selected ones at
    /// `opacity(0)`): one plain, one split in two, one split in three, one
    /// with two Tabs, plus `extraSessions` split in two. Session 0 is
    /// selected when hosting starts.
    static func standard(
        extraSessions: Int = 0,
        size: CGSize = CGSize(width: 1100, height: 700),
        store: AppStateStore = AppStateStore(),
        beforeHosting: (AppStateStore, WindowRuntime) -> Void = { _, _ in }
    ) -> SessionDetailFixture {
        SessionDetailFixture(store: store, size: size) { store, windowRuntime in
            let second = windowRuntime.addSession()
            if let paneID = second.tree.allPanes.first?.id {
                store.splitPane(id: paneID, direction: .horizontal)
            }
            let third = windowRuntime.addSession()
            if let paneID = third.tree.allPanes.first?.id {
                store.splitPane(id: paneID, direction: .vertical)
                store.splitPane(id: paneID, direction: .horizontal)
            }
            let fourth = windowRuntime.addSession()
            fourth.tree.allPanes.first?.addTab()
            for _ in 0..<extraSessions {
                let extra = windowRuntime.addSession()
                if let paneID = extra.tree.allPanes.first?.id {
                    store.splitPane(id: paneID, direction: .horizontal)
                }
            }
            windowRuntime.selectSession(at: 0)
            beforeHosting(store, windowRuntime)
        }
    }

    func tearDown() {
        for session in windowRuntime.sessions {
            for pane in session.tree.allPanes {
                for tab in pane.tabs {
                    TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
                }
                pane.content?.tearDown()
            }
        }
        TerminalHostStore.shared.releaseHost(forWindowID: windowRuntime.id)
        probe.window.close()
    }

    func terminalViewCount() -> Int {
        probe.allViews().filter { NSStringFromClass(type(of: $0)).contains("AppTerminalView") }.count
    }
}
