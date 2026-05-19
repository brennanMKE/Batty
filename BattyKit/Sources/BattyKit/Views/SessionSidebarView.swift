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
                SessionRow(session: session, accent: themeChrome?.accent)
                    .tag(session.id as UUID?)
                    .accessibilityIdentifier("session-row.\(session.title)")
                    .modifier(SidebarRowBackground(tint: rowBackground(for: session)))
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

    private func rowBackground(for session: SessionRuntime) -> Color? {
        guard session.id == store.selectedSessionID else { return nil }
        return themeChrome?.sidebarSelectionTint
    }
}

private struct SidebarRowBackground: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if let tint {
            content.listRowBackground(tint)
        } else {
            content
        }
    }
}

private struct SessionRow: View {
    @Bindable var session: SessionRuntime
    let accent: Color?

    var body: some View {
        HStack {
            Label {
                Text(session.title).lineLimit(1)
            } icon: {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
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
