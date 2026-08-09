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
        List(selection: sidebarSelection) {
            ForEach(windowRuntime.sessions) { session in
                // Native outline disclosure per session: the sidebar List
                // maps DisclosureGroup onto NSOutlineView expansion, which
                // is the only path that gives the animated height
                // reveal/collapse (chevron rotates right→down, rows slide
                // over a duration). Hand-rolled variants — `if` around the
                // ForEach, empty-data ForEach — apply without animation on
                // the NSTableView-backed List (#0258 follow-up).
                //
                // Pane rows: `selectionDisabled` is required — even without
                // a `.tag()`, macOS List derives an implicit selection value
                // from the ForEach identity, and `pane.id` type-matches the
                // UUID? selection; clicking a row would write a pane id into
                // selectedSessionID (#0258). Tapping a row instead selects
                // the owning session and focuses (un-hiding if needed).
                DisclosureGroup(isExpanded: Binding(
                    get: { session.isPaneListExpanded },
                    set: { session.isPaneListExpanded = $0 }
                )) {
                    ForEach(session.tree.panesSortedByColumnThenRow) { pane in
                        PaneRow(
                            pane: pane,
                            session: session,
                            windowRuntime: windowRuntime,
                            accent: themeChrome?.accent
                        )
                        .selectionDisabled()
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
                        .modifier(SidebarRowBackground(
                            sidebarBackground: themeChrome?.chromeBackground,
                            selectionTint: nil,
                            isSelected: false
                        ))
                        .accessibilityIdentifier("pane-row.\(pane.id.uuidString)")
                    }
                } label: {
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
                }
                .tag(session.id as UUID?)
                .accessibilityIdentifier("session-row.\(session.title)")
                .modifier(SidebarRowBackground(
                    sidebarBackground: themeChrome?.chromeBackground,
                    selectionTint: themeChrome?.sidebarSelectionTint,
                    isSelected: session.id == windowRuntime.selectedSessionID
                ))
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

    /// Routes List selection writes through the validated setter so pane ids
    /// (implicit-identity selection, #0258) and nil (empty-area click) never
    /// reach `selectedSessionID`. SwiftUI re-reads the getter after a rejected
    /// write and the List snaps back to the real selection.
    private var sidebarSelection: Binding<UUID?> {
        Binding(
            get: { windowRuntime.selectedSessionID },
            set: { windowRuntime.setSelectedSession(id: $0) }
        )
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

struct PaneRow: View {
    @Bindable var pane: PaneRuntime
    @Bindable var session: SessionRuntime
    @Bindable var windowRuntime: WindowRuntime
    let accent: Color?

    /// Column/row position (`1/1`, `2/1`, `1/3`, …) instead of the pane's
    /// path — the path gave no way to tell where a pane sat in the split
    /// layout and went stale on `cd` (#0259) — with the pane's **first**
    /// tab's chip value appended (#0260), so the row and that tab's chip
    /// always agree. "First" means first in tab order, independent of
    /// which tab is active or how tabs get reordered — the row describes
    /// the *pane*, and a pane's identity-bearing tab is its first one, the
    /// same rule ``AppStateStore``'s session anchor-tab naming uses one
    /// level up. Hidden panes keep the same coordinates as their tree slot.
    private var paneLabel: String {
        Self.label(
            position: session.tree.panePositions[pane.id]?.label ?? "?/?",
            firstTab: pane.tabs.first,
            kind: pane.kind
        )
    }

    /// `kind` defaults to `.terminal` so every existing call site (and
    /// `TabAutoNamingTests`' direct calls) keeps compiling and behaving
    /// unchanged. For a non-terminal pane, `firstTab` is a structural
    /// placeholder `PaneView` never renders (`PaneRuntime.kind`'s doc
    /// comment) — labeling the sidebar row from it would render
    /// `"2/1 — Tab"` on a Git Status pane, which looks broken (#0315 review
    /// round 1, finding 3). Label from the kind's display name instead.
    static func label(position: String, firstTab: TabRuntime?, kind: PaneContentKind = .terminal) -> String {
        guard kind == .terminal else { return "\(position) — \(kind.displayName)" }
        guard let firstTab else { return position }
        return "\(position) — \(TabTitleFormatter.chipTitle(for: firstTab))"
    }

    /// Eye can always be toggled to show; can only hide when other visible panes exist.
    private var eyeEnabled: Bool {
        pane.isHidden || session.tree.visiblePanes.count > 1
    }

    var body: some View {
        HStack(spacing: 6) {
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

            // The single visibility control: shows current state
            // (eye = visible, eye.slash = hidden), click toggles.
            Button {
                toggleVisibility()
            } label: {
                Image(systemName: pane.isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(pane.isHidden ? "Show pane" : "Hide pane")
            .disabled(!eyeEnabled)
            .accessibilityIdentifier("pane-eye-toggle.\(pane.id.uuidString)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            activate()
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

    /// Row tap: select the owning session, restore the pane if hidden
    /// (#0256's "selecting a hidden pane's row restores it"), and focus it.
    /// Event-origin writes; pane rows are `selectionDisabled` so this is the
    /// row's only activation path (#0258).
    private func activate() {
        windowRuntime.setSelectedSession(id: session.id)
        if pane.isHidden {
            windowRuntime.showPane(id: pane.id)
        }
        windowRuntime.focusPane(id: pane.id)
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
