// SessionDetailView.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SessionDetailView")

public struct SessionDetailView: View {
    public let store: AppStateStore
    public let windowRuntime: WindowRuntime
    @Environment(\.themeChrome) private var themeChrome
    @State private var bellFeedShown: Bool = false
    @State private var commandPaletteShown: Bool = false
    @State private var openQuicklyShown: Bool = false
    @State private var layoutPickerShown: Bool = false
    @State private var projectPickerShown: Bool = false
    @State private var afterProjectPicker: ProjectPickerAction?
    @State private var afterCommandPalette: (@MainActor () -> Void)?
    @State private var themeSelectorShown: Bool = false
    @State private var pendingPaste: PendingPaste?
    @State private var splitDetailToolbarSafeInsetTop: CGFloat = -1

    public init(store: AppStateStore, windowID: WindowID) {
        self.store = store
        self.windowRuntime = store.windowRuntime(for: windowID)
    }

    public var body: some View {
        decoratedStack
    }

    @ViewBuilder private var decoratedStack: some View {
        configuredStack
        // Each window has its own SessionDetailView subscribed to the same
        // app-wide NotificationCenter, so every one of these toggles is
        // delivered to every window. Only the key content window may act —
        // otherwise a single Cmd-shortcut opens the picker in all windows
        // (#0242). Same guard as the sidebar toggle in RootWindowView.
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleBellFeed)) { _ in
            guard isKeyWindow else { return }
            bellFeedShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleCommandPalette)) { _ in
            guard isKeyWindow else { return }
            commandPaletteShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleOpenQuickly)) { _ in
            guard isKeyWindow else { return }
            openQuicklyShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleLayoutPicker)) { _ in
            guard isKeyWindow else { return }
            layoutPickerShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleProjectPicker)) { _ in
            guard store.featureFlags.projects, isKeyWindow else { return }
            projectPickerShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleThemeSelector)) { _ in
            guard isKeyWindow else { return }
            themeSelectorShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyRequestPaste)) { note in
            guard isKeyWindow else { return }
            guard let pending = note.userInfo?["paste"] as? PendingPaste else { return }
            pendingPaste = pending
        }
        .sheet(item: $pendingPaste) { pending in
            PasteConfirmationSheet(
                paste: pending,
                onConfirm: { _ in
                    PasteDispatcher.confirm(pending, in: store)
                    pendingPaste = nil
                },
                onCancel: { pendingPaste = nil }
            )
        }
        .sheet(isPresented: $commandPaletteShown, onDismiss: runAfterCommandPalette) {
            CommandPaletteView(
                isPresented: $commandPaletteShown,
                store: store,
                afterDismiss: { afterCommandPalette = $0 }
            )
        }
        .sheet(isPresented: $openQuicklyShown) {
            OpenQuicklyView(isPresented: $openQuicklyShown, windowRuntime: windowRuntime)
        }
        .sheet(isPresented: $layoutPickerShown) {
            LayoutPickerView(isPresented: $layoutPickerShown, windowRuntime: windowRuntime)
        }
        .sheet(isPresented: projectPickerBinding, onDismiss: runAfterProjectPicker) {
            ProjectPickerView(
                projects: { store.projectStore?.projects ?? [] },
                openProjectIDs: { store.openProjectIDs },
                onAction: { action in
                    afterProjectPicker = action
                    projectPickerShown = false
                },
                onCancel: { projectPickerShown = false }
            )
        }
        .sheet(isPresented: $themeSelectorShown) {
            ThemeSelectorView(isPresented: $themeSelectorShown, store: store)
        }
        .sheet(item: startupTrustBinding) { request in
            ProjectStartupTrustSheet(request: request) { choice in
                store.resolveStartupTrust(requestID: request.id, choice: choice)
            }
        }
        .confirmationDialog(
            windowRuntime.pendingCloseRequest?.title ?? "",
            isPresented: pendingCloseBinding,
            titleVisibility: .visible,
            presenting: windowRuntime.pendingCloseRequest
        ) { _ in
            Button("Close", role: .destructive) {
                windowRuntime.confirmPendingClose()
            }
            Button("Cancel", role: .cancel) {
                windowRuntime.cancelPendingClose()
            }
        } message: { request in
            Text(request.message)
        }
        // #0390: a terminal program's clipboard-read request (OSC 52 /
        // Kitty clipboard protocol). Bound to the *selected* Session's
        // pending confirmation — a request from a non-selected Session's
        // Pane waits until the user switches to it. The `pending` captured
        // here (from `presenting:`) is threaded into every action instead
        // of re-reading `windowRuntime.selectedSession?.pendingClipboardConfirmation`
        // at tap time: a second request can displace this one while the
        // dialog is still showing (`SessionRuntime.requestClipboardReadConfirmation`
        // denies the displaced one immediately), and resolving by identity
        // means a stale tap against the request the user actually read
        // safely no-ops instead of answering whatever is live now (#0390
        // round 2, B2). Switching Sessions away from a still-pending
        // request denies it explicitly in the `selectedSessionID`
        // `onChange` above, rather than relying on this dialog's own
        // dismiss handler below, which by then would be reading the
        // newly-selected Session, not the one that owned the request
        // (#0390 round 2, B3). Dismissing without an explicit answer
        // (Escape, click-outside) denies via `pendingClipboardConfirmationBinding`
        // below, never a silent allow.
        .confirmationDialog(
            windowRuntime.selectedSession?.pendingClipboardConfirmation?.title ?? "",
            isPresented: pendingClipboardConfirmationBinding,
            titleVisibility: .visible,
            presenting: windowRuntime.selectedSession?.pendingClipboardConfirmation
        ) { pending in
            Button("Allow") {
                windowRuntime.selectedSession?.answerPendingClipboardConfirmation(pending, allow: true)
            }
            Button("Deny", role: .cancel) {
                windowRuntime.selectedSession?.answerPendingClipboardConfirmation(pending, allow: false)
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    @ViewBuilder private var configuredStack: some View {
        sessionStack
        .navigationTitle(navigationTitle)
        .toolbar { toolbarItems }
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) {
            splitDetailToolbarSafeInsetTop = $0
        }
        .environment(\.splitDetailToolbarSafeInsetTop, splitDetailToolbarSafeInsetTop)
        .onAppear {
            logger.debug("onAppear: selectedSession=\(windowRuntime.selectedSession?.title ?? "nil", privacy: .public)")
            focusSelectedSessionTerminal()
            windowRuntime.markActiveTabSeen()
            store.applyActiveSessionTheme(for: windowRuntime.selectedSession)
        }
        .onChange(of: windowRuntime.selectedSessionID) { old, new in
            logger.debug("selectedSessionID changed: \(old?.uuidString ?? "nil", privacy: .public) → \(new?.uuidString ?? "nil", privacy: .public)")
            focusSelectedSessionTerminal()
            windowRuntime.markActiveTabSeen()
            store.applyActiveSessionTheme(for: windowRuntime.selectedSession)
            // #0390 round 2, B3: deny a clipboard confirmation left pending
            // on the Session being navigated away from, right here and
            // synchronously — not left for `pendingClipboardConfirmationBinding`'s
            // dismiss handler, which by the time SwiftUI calls it is
            // already reading the *new* selectedSession (whose pending is
            // nil) and so silently no-ops, orphaning the old request until
            // Session teardown eventually denies it or the user switches
            // back to a stale, out-of-context prompt.
            if let old, let previousSession = store.session(id: old),
               let pending = previousSession.pendingClipboardConfirmation {
                previousSession.cancelPendingClipboardConfirmation(pending)
            }
        }
        .onChange(of: windowRuntime.selectedSession?.tree.focusedPaneID) { _, _ in
            windowRuntime.markActiveTabSeen()
        }
        .onChange(of: windowRuntime.selectedSession?.tree.allPanes.count) { _, newCount in
            logger.debug("allPanes.count changed → \(newCount ?? 0, privacy: .public); re-applying theme")
            store.applyActiveSessionTheme(for: windowRuntime.selectedSession)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                guard let tree = windowRuntime.selectedSession?.tree else { return }
                if NSEvent.modifierFlags.contains(.option) {
                    tree.splitFullDimension(direction: .horizontal, inheritingFrom: tree.focusedPane)
                } else {
                    tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
                }
            } label: {
                Label("Split Horizontally", systemImage: "rectangle.split.2x1")
            }
            .help("Split Horizontally (\u{2318}D) \u{2014} Option for a full-height column (\u{2325}\u{2318}D)")
            .accessibilityIdentifier("toolbar.split-horizontal")
            .disabled(windowRuntime.selectedSession == nil)

            Button {
                guard let tree = windowRuntime.selectedSession?.tree else { return }
                if NSEvent.modifierFlags.contains(.option) {
                    tree.splitFullDimension(direction: .vertical, inheritingFrom: tree.focusedPane)
                } else {
                    tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
                }
            } label: {
                Label("Split Vertically", systemImage: "rectangle.split.1x2")
            }
            .help("Split Vertically (\u{2318}\u{21E7}D) \u{2014} Option for a full-width row (\u{2325}\u{2318}\u{21E7}D)")
            .accessibilityIdentifier("toolbar.split-vertical")
            .disabled(windowRuntime.selectedSession == nil)

            Button {
                bellFeedShown.toggle()
            } label: {
                Label(
                    "Bell Feed",
                    systemImage: store.bellFeed.unseenCount > 0 ? "bell.badge" : "bell"
                )
                .symbolRenderingMode(.hierarchical)
            }
            .help("Bell Feed (\u{2318}\u{21E7}N)")
            .popover(isPresented: $bellFeedShown, arrowEdge: .top) {
                BellFeedView(
                    store: store,
                    onJump: { entry in
                        bellFeedShown = false
                        store.jumpToBellEntry(entry)
                    },
                    onDismiss: { bellFeedShown = false }
                )
            }
        }
    }

    @ViewBuilder private var sessionStack: some View {
        ZStack {
            // The long-lived terminal host fills the entire detail area.
            // One host per content window, keyed by windowID. makeNSView
            // returns the same TerminalHostView instance for the window
            // every time, so SwiftUI rebuilds (sidebar collapse, navigation
            // churn, session selection changes, etc.) never destroy the host
            // or its terminal subviews. Placed below the session chrome in
            // the ZStack so terminals render behind chips / sidebar overlays.
            // AppKit hit-testing on TerminalHostView routes clicks inside a
            // visible terminal frame to that terminal; clicks outside fall
            // through to SwiftUI.
            TerminalHostInstaller(windowID: windowRuntime.id)

            ForEach(windowRuntime.sessions) { session in
                SplitContainerView(tree: session.tree)
                    .coordinateSpace(name: "session")
                    .onPreferenceChange(PaneFramePreferenceKey.self) { newFrames in
                        session.paneFrames.frames = newFrames
                    }
                    .environment(\.isSelectedSession, session.id == windowRuntime.selectedSessionID)
                    .opacity(session.id == windowRuntime.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == windowRuntime.selectedSessionID)
            }
            if windowRuntime.selectedSession == nil {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Pick a session in the sidebar or create one with the + button.")
                )
            }
        }
        // Themed window background fills behind the terminal host and into
        // the transparent title bar (`WindowChromeApplier`).
        .background(
            themeChrome?.windowBackground ?? Color.clear,
            ignoresSafeAreaEdges: .all
        )
        .coordinateSpace(name: TerminalHostInstaller.coordinateSpaceName)
        .environment(\.windowID, windowRuntime.id)
        .frame(minWidth: 600, minHeight: 400)
    }

    private var isKeyWindow: Bool {
        store.keyWindowRuntime()?.id == windowRuntime.id
    }

    private var projectPickerBinding: Binding<Bool> {
        Binding(
            get: { store.featureFlags.projects && projectPickerShown },
            set: { projectPickerShown = $0 }
        )
    }

    private func runAfterCommandPalette() {
        guard let work = afterCommandPalette else { return }
        afterCommandPalette = nil
        work()
    }

    private func runAfterProjectPicker() {
        guard let action = afterProjectPicker else { return }
        afterProjectPicker = nil
        switch action {
        case .open(let id, let mode):
            ProjectOpenPresenter.open(id: id, mode: mode, in: store)
        case .edit(let id):
            ProjectEditorWindowController.shared.show(store: store, selecting: id)
        case .newProject:
            ProjectEditorWindowController.shared.show(store: store, startNewProject: true)
        }
    }

    private var startupTrustBinding: Binding<ProjectStartupTrustRequest?> {
        let shown = store.featureFlags.projects ? windowRuntime.pendingStartupTrusts.first : nil
        return Binding(
            get: { shown },
            set: { newValue in
                if newValue == nil, let shown {
                    store.cancelStartupTrust(requestID: shown.id)
                }
            }
        )
    }

    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: { windowRuntime.pendingCloseRequest != nil },
            set: { newValue in
                if !newValue { windowRuntime.cancelPendingClose() }
            }
        )
    }

    private var pendingClipboardConfirmationBinding: Binding<Bool> {
        Binding(
            get: { windowRuntime.selectedSession?.pendingClipboardConfirmation != nil },
            set: { newValue in
                guard !newValue,
                      let session = windowRuntime.selectedSession,
                      let pending = session.pendingClipboardConfirmation
                else { return }
                session.cancelPendingClipboardConfirmation(pending)
            }
        )
    }

    private var navigationTitle: String {
        windowRuntime.selectedSession?.title ?? "Batty"
    }

    private func focusSelectedSessionTerminal() {
        guard let session = windowRuntime.selectedSession else { return }
        // Deliberately `focusedPaneAnyKind`, not `focusedTerminalPane`
        // (#0332 B4, reverted from an earlier round's gate): gating this on
        // `.terminal` kind would skip `focusWhenReady`'s `generation += 1`
        // bump on the early-return path, leaving a still-live retry ladder
        // from a *previously* focused tab free to keep firing after focus
        // has moved to a non-terminal pane — the exact stale-retry /
        // isFocused-echo ping-pong `generation`'s own doc comment
        // (`TerminalSurfaceFocuser.swift`) says it exists to prevent
        // (#0229, #0230). `focus(tab:)`'s own `view.window != nil` /
        // `!view.isHidden` guards make a non-terminal pane's placeholder
        // tab (`activeTab` here) a harmless no-op target today — this was
        // already dead code for that case before #0332 touched it, and
        // gating it here bought nothing but risk in the most fragile area
        // of the app (`docs/swiftui-observation-rules.md`).
        guard let activeTab = session.focusedPaneAnyKind.activeTab else { return }
        TerminalSurfaceFocuser.focusWhenReady(tab: activeTab)
    }
}
