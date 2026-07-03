// SessionSidebarView.swift

import SwiftUI

public struct SessionSidebarView: View {
    @Bindable public var windowRuntime: WindowRuntime
    public let store: AppStateStore
    @Environment(\.themeChrome) private var themeChrome
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""
    @State private var themingSessionID: UUID?

    public init(store: AppStateStore, windowID: WindowID) {
        self.store = store
        self.windowRuntime = store.windowRuntime(for: windowID)
    }

    public var body: some View {
        List(selection: $windowRuntime.selectedSessionID) {
            ForEach(windowRuntime.sessions) { session in
                SessionRow(
                    session: session,
                    store: store,
                    windowRuntime: windowRuntime,
                    accent: themeChrome?.accent,
                    onRename: {
                        renameDraft = session.title
                        renamingSessionID = session.id
                    },
                    onTheme: {
                        themingSessionID = session.id
                    }
                )
                .tag(session.id as UUID?)
                .accessibilityIdentifier("session-row.\(session.title)")
                .modifier(SidebarRowBackground(
                    sidebarBackground: themeChrome?.chromeBackground,
                    selectionTint: themeChrome?.sidebarSelectionTint,
                    isSelected: session.id == windowRuntime.selectedSessionID
                ))

                // Pane rows: shown when the session has >1 pane (split).
                // Each row carries the eye toggle and bell badge.
                // Non-selectable — they carry no List tag (#0256).
                if session.tree.allPanes.count > 1 {
                    ForEach(Array(session.tree.allPanes.enumerated()), id: \.element.id) { index, pane in
                        PaneRow(
                            pane: pane,
                            paneIndex: index + 1,
                            session: session,
                            windowRuntime: windowRuntime,
                            accent: themeChrome?.accent
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 28, bottom: 2, trailing: 8))
                        .modifier(SidebarRowBackground(
                            sidebarBackground: themeChrome?.chromeBackground,
                            selectionTint: nil,
                            isSelected: false
                        ))
                        .accessibilityIdentifier("pane-row.\(pane.id.uuidString)")
                    }
                }
            }
            .onMove { source, destination in
                windowRuntime.moveSessions(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(themeChrome?.chromeBackground == nil ? .automatic : .hidden)
        .background(themeChrome?.chromeBackground ?? Color.clear)
        .accessibilityIdentifier("session-sidebar")
        .navigationTitle(Text(verbatim: "Batty"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    windowRuntime.addSession()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("New Session")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if let bg = themeChrome?.chromeBackground {
                    bg.overlay(themeChrome?.divider ?? Color.clear, alignment: .top)
                } else {
                    Color.clear.background(.bar)
                }
            }
        }
        .sheet(item: renamingBinding) { session in
            RenameSessionSheet(
                title: $renameDraft,
                onCommit: {
                    windowRuntime.renameSession(id: session.id, to: renameDraft)
                    renamingSessionID = nil
                },
                onCancel: { renamingSessionID = nil }
            )
        }
        .sheet(item: themingBinding) { session in
            SessionThemeSelectorView(
                isPresented: themingPresentedBinding,
                store: store,
                session: session
            )
        }
    }

    private var renamingBinding: Binding<SessionRuntime?> {
        Binding(
            get: { windowRuntime.sessions.first { $0.id == renamingSessionID } },
            set: { renamingSessionID = $0?.id }
        )
    }

    private var themingBinding: Binding<SessionRuntime?> {
        Binding(
            get: { windowRuntime.sessions.first { $0.id == themingSessionID } },
            set: { themingSessionID = $0?.id }
        )
    }

    private var themingPresentedBinding: Binding<Bool> {
        Binding(
            get: { themingSessionID != nil },
            set: { if !$0 { themingSessionID = nil } }
        )
    }

}

private struct SidebarRowBackground: ViewModifier {
    let sidebarBackground: Color?
    let selectionTint: Color?
    let isSelected: Bool

    func body(content: Content) -> some View {
        if sidebarBackground != nil {
            // Selected: paint sidebarBackground first, then overlay the
            // subtle selection tint. Unselected: just sidebarBackground.
            // Painting an explicit row background suppresses SwiftUI's
            // `.sidebar` default selection chrome — without this, the
            // system paints a fixed dark gray block on the selected row
            // that ignores the themed sidebar (see #0135 round 2). The
            // selection tint is a foreground@12% overlay (#0135 round 5),
            // adaptive and subtle on every theme.
            content.listRowBackground(
                ZStack {
                    if let sidebarBackground {
                        sidebarBackground
                    }
                    if isSelected, let selectionTint {
                        selectionTint
                    }
                }
            )
        } else {
            content
        }
    }
}

private struct SessionRow: View {
    @Bindable var session: SessionRuntime
    let store: AppStateStore
    let windowRuntime: WindowRuntime
    let accent: Color?
    let onRename: () -> Void
    let onTheme: () -> Void

    var body: some View {
        HStack {
            Label {
                Text(session.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(HierarchicalShapeStyle.secondary)
            }
            Spacer()
            if session.unseenBellCount > 0 {
                Text(verbatim: "\(session.unseenBellCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().stroke(accent ?? Color.accentColor, lineWidth: 1))
                    .help("\(session.unseenBellCount) unseen bell event(s)")
            }
        }
        .contextMenu {
            Button("Rename") { onRename() }
            Button("Reset Name") {
                windowRuntime.clearSessionName(id: session.id)
            }
            .disabled(AppStateStore.isDefaultSessionTitle(session.title))
            Divider()
            Button("Set Session Theme\u{2026}") { onTheme() }
            if session.localThemeName != nil {
                Button("Clear Session Theme") {
                    session.localThemeName = nil
                    if session.id == windowRuntime.selectedSessionID {
                        store.applyActiveSessionTheme(for: windowRuntime.selectedSession)
                    }
                }
            }
            Divider()
            Button(session.notificationsMuted
                ? String(localized: "Unmute Notifications")
                : String(localized: "Mute Notifications")) {
                session.notificationsMuted.toggle()
            }
            Divider()
            Button("Close", role: .destructive) {
                windowRuntime.removeSession(id: session.id)
            }
        }
    }
}

private struct PaneRow: View {
    @Bindable var pane: PaneRuntime
    let paneIndex: Int
    @Bindable var session: SessionRuntime
    @Bindable var windowRuntime: WindowRuntime
    let accent: Color?

    private var paneLabel: String {
        if let activeTab = pane.activeTab {
            let title: String
            if let override = activeTab.titleOverride, !override.isEmpty {
                title = override
            } else {
                title = activeTab.terminal.title
            }
            if !title.isEmpty { return title }
        }
        return String(localized: "Pane \(paneIndex)")
    }

    /// Eye can always be toggled to show; can only hide when other visible panes exist.
    private var eyeEnabled: Bool {
        pane.isHidden || session.tree.visiblePanes.count > 1
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pane.isHidden ? "eye.slash" : "eye")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            Text(paneLabel)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(pane.isHidden ? Color.secondary : Color.primary)

            Spacer()

            if pane.unseenBellCount > 0 {
                Text(verbatim: "\(pane.unseenBellCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().stroke(accent ?? Color.accentColor, lineWidth: 1))
                    .help("\(pane.unseenBellCount) unseen bell event(s)")
            }

            Button {
                toggleVisibility()
            } label: {
                Image(systemName: pane.isHidden ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(pane.isHidden ? "Show pane" : "Hide pane")
            .disabled(!eyeEnabled)
            .accessibilityIdentifier("pane-eye-toggle.\(pane.id.uuidString)")
        }
    }

    /// Toggle hide/show through WindowRuntime so every entry point drives
    /// TerminalHostStore and the last-visible guard together. Event-origin
    /// (button tap) — safe per `docs/swiftui-observation-rules.md`.
    private func toggleVisibility() {
        if pane.isHidden {
            windowRuntime.showPane(id: pane.id)
        } else {
            windowRuntime.hidePane(id: pane.id)
        }
    }
}

private struct RenameSessionSheet: View {
    @Binding var title: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Session").font(.headline)
            TextField("Session name", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}
