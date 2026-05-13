// SessionDetailView.swift

import SwiftUI

public struct SessionDetailView: View {
    public let store: AppStateStore
    @State private var bellFeedShown: Bool = false
    @State private var pendingPaste: PendingPaste?

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
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
        .coordinateSpace(name: TerminalHostInstaller.coordinateSpaceName)
        .onPreferenceChange(TerminalPlacementPreferenceKey.self) { newPlacements in
            TerminalHostStore.shared.updatePlacements(newPlacements)
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(navigationTitle)
        .toolbar {
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
        .onAppear {
            focusSelectedSessionTerminal()
            store.markActiveTabSeen()
        }
        .onChange(of: store.selectedSessionID) { _, _ in
            focusSelectedSessionTerminal()
            store.markActiveTabSeen()
        }
        .onChange(of: store.selectedSession?.tree.focusedPaneID) { _, _ in
            store.markActiveTabSeen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .battyToggleBellFeed)) { _ in
            bellFeedShown.toggle()
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
        TerminalSurfaceFocuser.focusWhenReady(terminal: activeTab.terminal)
    }
}
