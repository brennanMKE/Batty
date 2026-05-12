// SessionSidebarView.swift

import SwiftUI

public struct SessionSidebarView: View {
    @Bindable public var store: AppStateStore
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    public init(store: AppStateStore) {
        self.store = store
    }

    public var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.sessions) { session in
                SessionRow(session: session)
                    .tag(session.id as UUID?)
                    .accessibilityIdentifier("session-row.\(session.title)")
                    .contextMenu {
                        Button("Rename") {
                            renameDraft = session.title
                            renamingSessionID = session.id
                        }
                        Button("Duplicate") {
                            store.duplicateSession(id: session.id)
                        }
                        Divider()
                        Button(session.notificationsMuted ? "Unmute Notifications" : "Mute Notifications") {
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
        .accessibilityIdentifier("session-sidebar")
        .navigationTitle("Batty")
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
            .background(.bar)
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

private struct SessionRow: View {
    @Bindable var session: SessionRuntime

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
                Text("\(session.unseenBellCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .help("\(session.unseenBellCount) unseen bell event\(session.unseenBellCount == 1 ? "" : "s")")
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
