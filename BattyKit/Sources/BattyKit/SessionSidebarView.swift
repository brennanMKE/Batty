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
                    .contextMenu {
                        Button("Rename") {
                            renameDraft = session.title
                            renamingSessionID = session.id
                        }
                        Button("Duplicate") {
                            store.duplicateSession(id: session.id)
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
        .navigationTitle("Batty")
        .toolbar {
            ToolbarItem {
                Button {
                    store.addSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session")
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

private struct SessionRow: View {
    @Bindable var session: SessionRuntime

    var body: some View {
        Label {
            Text(displayTitle).lineLimit(1)
        } icon: {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
        }
    }

    private var displayTitle: String {
        let live = session.terminal.title
        return live.isEmpty ? session.title : live
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
