// SessionDetailView.swift

import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SessionDetailView")

public struct SessionDetailView: View {
    public let store: AppStateStore
    @Environment(\.themeChrome) private var themeChrome
    @State private var bellFeedShown: Bool = false
    @State private var commandPaletteShown: Bool = false
    @State private var openQuicklyShown: Bool = false
    @State private var layoutPickerShown: Bool = false
    @State private var themeSelectorShown: Bool = false
    @State private var pendingPaste: PendingPaste?
    @State private var splitDetailToolbarSafeInsetTop: CGFloat = -1

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
        decoratedStack
    }

    @ViewBuilder private var decoratedStack: some View {
        configuredStack
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleBellFeed)) { _ in
            bellFeedShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleCommandPalette)) { _ in
            commandPaletteShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleOpenQuickly)) { _ in
            openQuicklyShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleLayoutPicker)) { _ in
            layoutPickerShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleThemeSelector)) { _ in
            themeSelectorShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyRequestPaste)) { note in
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
        .sheet(isPresented: $commandPaletteShown) {
            CommandPaletteView(isPresented: $commandPaletteShown, store: store)
        }
        .sheet(isPresented: $openQuicklyShown) {
            OpenQuicklyView(isPresented: $openQuicklyShown, store: store)
        }
        .sheet(isPresented: $layoutPickerShown) {
            LayoutPickerView(isPresented: $layoutPickerShown, store: store)
        }
        .sheet(isPresented: $themeSelectorShown) {
            ThemeSelectorView(isPresented: $themeSelectorShown, store: store)
        }
        .confirmationDialog(
            store.pendingCloseRequest?.title ?? "",
            isPresented: pendingCloseBinding,
            titleVisibility: .visible,
            presenting: store.pendingCloseRequest
        ) { _ in
            Button("Close", role: .destructive) {
                store.confirmPendingClose()
            }
            Button("Cancel", role: .cancel) {
                store.cancelPendingClose()
            }
        } message: { request in
            Text(request.message)
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
            logger.debug("onAppear: selectedSession=\(store.selectedSession?.title ?? "nil", privacy: .public)")
            focusSelectedSessionTerminal()
            store.markActiveTabSeen()
            store.applyActiveSessionTheme()
        }
        .onChange(of: store.selectedSessionID) { old, new in
            logger.debug("selectedSessionID changed: \(old?.uuidString ?? "nil", privacy: .public) → \(new?.uuidString ?? "nil", privacy: .public)")
            focusSelectedSessionTerminal()
            store.markActiveTabSeen()
            store.applyActiveSessionTheme()
        }
        .onChange(of: store.selectedSession?.tree.focusedPaneID) { _, _ in
            store.markActiveTabSeen()
        }
        .onChange(of: store.selectedSession?.tree.allPanes.count) { _, newCount in
            logger.debug("allPanes.count changed → \(newCount ?? 0, privacy: .public); re-applying theme")
            store.applyActiveSessionTheme()
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .horizontal, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Horizontally", systemImage: "rectangle.split.2x1")
            }
            .help("Split Horizontally (\u{2318}D)")
            .accessibilityIdentifier("toolbar.split-horizontal")
            .disabled(store.selectedSession == nil)

            Button {
                guard let tree = store.selectedSession?.tree else { return }
                tree.splitFocusedPane(direction: .vertical, inheritingFrom: tree.focusedPane)
            } label: {
                Label("Split Vertically", systemImage: "rectangle.split.1x2")
            }
            .help("Split Vertically (\u{2318}\u{21E7}D)")
            .accessibilityIdentifier("toolbar.split-vertical")
            .disabled(store.selectedSession == nil)

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
                BellFeedView(store: store) { entry in
                    bellFeedShown = false
                    store.jumpToBellEntry(entry)
                }
            }
        }
    }

    @ViewBuilder private var sessionStack: some View {
        ZStack {
            // The long-lived terminal host fills the entire detail area.
            // It's a singleton-backed NSViewRepresentable: makeNSView
            // returns the same TerminalHostView instance every time, so
            // SwiftUI rebuilds (sidebar collapse, navigation churn,
            // session selection changes, etc.) never destroy the host
            // or its terminal subviews. Placed below the session chrome
            // in the ZStack so terminals render behind chips / sidebar
            // overlays. AppKit hit-testing on TerminalHostView routes
            // clicks inside a visible terminal frame to that terminal;
            // clicks outside fall through to SwiftUI.
            TerminalHostInstaller()

            ForEach(store.sessions) { session in
                SplitContainerView(tree: session.tree)
                    .coordinateSpace(name: "session")
                    .onPreferenceChange(PaneFramePreferenceKey.self) { newFrames in
                        session.paneFrames.frames = newFrames
                    }
                    .environment(\.isSelectedSession, session.id == store.selectedSessionID)
                    .opacity(session.id == store.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == store.selectedSessionID)
            }
            if store.selectedSession == nil {
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
        .frame(minWidth: 600, minHeight: 400)
    }

    private var pendingCloseBinding: Binding<Bool> {
        Binding(
            get: { store.pendingCloseRequest != nil },
            set: { newValue in
                if !newValue { store.cancelPendingClose() }
            }
        )
    }

    private var navigationTitle: String {
        store.selectedSession?.title ?? "Batty"
    }

    private func focusSelectedSessionTerminal() {
        guard let session = store.selectedSession else { return }
        guard let activeTab = session.focusedPane.activeTab else { return }
        TerminalSurfaceFocuser.focusWhenReady(tab: activeTab)
    }
}
