// SessionSidebarView.swift

import SwiftUI

public struct SessionSidebarView: View {
    @Bindable public var store: AppStateStore
    @Environment(\.themeChrome) private var themeChrome
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.sessions) { session in
                SessionRow(
                    session: session,
                    accent: themeChrome?.accent,
                    isSelected: session.id == store.selectedSessionID,
                    themed: themeChrome?.chromeBackground != nil
                )
                    .tag(session.id as UUID?)
                    .accessibilityIdentifier("session-row.\(session.title)")
                    .modifier(SidebarRowBackground(
                        sidebarBackground: themeChrome?.chromeBackground
                    ))
                    .contextMenu {
                        Button("Rename") {
                            renameDraft = session.title
                            renamingSessionID = session.id
                        }
                        Button("Duplicate") {
                            store.duplicateSession(id: session.id)
                        }
                        Divider()
                        Button(session.notificationsMuted
                            ? String(localized: "Unmute Notifications")
                            : String(localized: "Mute Notifications")) {
                            session.notificationsMuted.toggle()
                        }
                        Divider()
                        Button("Close", role: .destructive) {
                            store.removeSession(id: session.id)
                        }
                    }
            }
            .onMove { source, destination in
                store.moveSessions(fromOffsets: source, toOffset: destination)
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
                    store.addSession()
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
                    store.renameSession(id: session.id, to: renameDraft)
                    renamingSessionID = nil
                },
                onCancel: { renamingSessionID = nil }
            )
        }
    }

    private var renamingBinding: Binding<SessionRuntime?> {
        Binding(
            get: { store.sessions.first { $0.id == renamingSessionID } },
            set: { renamingSessionID = $0?.id }
        )
    }

}

private struct SidebarRowBackground: ViewModifier {
    let sidebarBackground: Color?

    func body(content: Content) -> some View {
        if let sidebarBackground {
            // Painting an explicit themed background on every row suppresses
            // SwiftUI's `.sidebar` default selection chrome — without this,
            // the system paints a fixed dark gray block on the selected row
            // that ignores the themed sidebar (see #0135 round 2). With no
            // theme applied, we leave the modifier off so the default
            // selection chrome still applies on the "Default" path.
            content.listRowBackground(sidebarBackground)
        } else {
            content
        }
    }
}

private struct SessionRow: View {
    @Bindable var session: SessionRuntime
    let accent: Color?
    let isSelected: Bool
    let themed: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isSelected && themed ? (accent ?? Color.accentColor) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 2)
            HStack {
                Label {
                    Text(session.title)
                        .lineLimit(1)
                        .fontWeight(isSelected && themed ? .semibold : .regular)
                } icon: {
                    Image(systemName: "rectangle.split.3x1")
                        .foregroundStyle(isSelected && themed
                            ? AnyShapeStyle(accent ?? Color.accentColor)
                            : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
                Spacer()
                if session.unseenBellCount > 0 {
                    Text(verbatim: "\(session.unseenBellCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent ?? Color.accentColor))
                        .help("\(session.unseenBellCount) unseen bell event(s)")
                }
            }
            .padding(.leading, 6)
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
