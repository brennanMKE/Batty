// ServersListView.swift

import SwiftUI

/// The Servers popover: one row per running server, with Copy URL.
struct ServersListView: View {
    let store: AppStateStore

    var body: some View {
        let entries = store.servers.activeEntries
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No servers running")
                    Text("Start one with batty server start or batty server serve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("servers.empty")
            } else {
                ForEach(entries, id: \.id) { entry in
                    ServerRow(store: store, entry: entry)
                    if entry.id != entries.last?.id { Divider() }
                }
            }
        }
        .frame(minWidth: 300)
    }
}

private struct ServerRow: View {
    let store: AppStateStore
    let entry: ServerEntry

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ServerEntryDisplay.name(for: entry))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ServerEntryDisplay.address(port: entry.port))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("servers.port")
                    Text(ServerEntryDisplay.stateText(entry.state, isResponding: entry.isResponding, kind: entry.backend.kind))
                        .font(.caption)
                        .foregroundStyle(color(ServerEntryDisplay.tone(entry.state, isResponding: entry.isResponding)))
                        .accessibilityIdentifier("servers.state")
                }
            }
            Spacer(minLength: 8)
            Button {
                store.copyServerURL(entry)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy URL")
            .accessibilityIdentifier("servers.copy-url")
            if entry.tailnetURL != nil {
                Button {
                    store.copyServerTailnetURL(entry)
                } label: {
                    Label("Copy Tailnet URL", systemImage: "network")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Tailnet URL")
                .accessibilityIdentifier("servers.copy-tailnet-url")
            }
            rowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("servers.row.\(entry.id.uuidString)")
    }

    private var rowMenu: some View {
        Menu {
            Button("Open in Browser") { store.openServerInBrowser(entry) }
                .accessibilityIdentifier("servers.row.open-in-browser")
            if store.serverTerminalTabID(entry) != nil {
                Button("Show Terminal") { store.showServerTerminal(entry) }
                    .accessibilityIdentifier("servers.row.show-terminal")
            }
            if ServerEntryDisplay.offersStopAndRestart(kind: entry.backend.kind) {
                Divider()
                Button("Restart") { entry.restart() }
                    .disabled(!entry.canRestart)
                    .accessibilityIdentifier("servers.row.restart")
                    .help(entry.stopRefusal ?? "")
                Button("Stop") { entry.stop() }
                    .disabled(!entry.canStop)
                    .accessibilityIdentifier("servers.row.stop")
                    .help(entry.stopRefusal ?? "")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("More")
        .accessibilityIdentifier("servers.row-menu")
    }

    private func color(_ tone: ServerEntryDisplay.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}
