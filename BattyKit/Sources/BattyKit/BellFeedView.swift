// BellFeedView.swift

import SwiftUI

public struct BellFeedView: View {
    let store: AppStateStore
    let onJump: ((BellFeedEntry) -> Void)?

    @State private var selectedEntryID: UUID?

    public init(store: AppStateStore, onJump: ((BellFeedEntry) -> Void)? = nil) {
        self.store = store
        self.onJump = onJump
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.bellFeed.entries.isEmpty {
                ContentUnavailableView(
                    "No bell events",
                    systemImage: "bell.slash",
                    description: Text("Bell events from your terminals show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedEntryID) {
                    ForEach(store.bellFeed.entries) { entry in
                        BellFeedRow(
                            entry: entry,
                            path: pathLabel(for: entry)
                        )
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture { handleJump(to: entry) }
                    }
                }
                .listStyle(.plain)
                .onKeyPress(.return) {
                    guard let id = selectedEntryID,
                          let entry = store.bellFeed.entries.first(where: { $0.id == id })
                    else { return .ignored }
                    handleJump(to: entry)
                    return .handled
                }
            }
        }
        .frame(width: 360, height: 420)
    }

    private var header: some View {
        HStack {
            Text("Bell Feed")
                .font(.headline)
            Spacer()
            if !store.bellFeed.entries.isEmpty {
                Button("Clear All") {
                    store.markAllBellsSeen()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handleJump(to entry: BellFeedEntry) {
        store.markBellSeen(id: entry.id)
        onJump?(entry)
    }

    private func pathLabel(for entry: BellFeedEntry) -> String {
        guard let session = store.sessions.first(where: { $0.id == entry.sessionID }),
              let pane = session.tree.allPanes.first(where: { $0.id == entry.paneID }),
              let tab = pane.tabs.first(where: { $0.id == entry.tabID })
        else {
            return "(closed)"
        }
        let paneIndex = (session.tree.allPanes.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1
        let tabIndex = (pane.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        let tabLabel: String
        if let override = tab.titleOverride, !override.isEmpty {
            tabLabel = override
        } else if !tab.terminal.title.isEmpty {
            tabLabel = tab.terminal.title
        } else {
            tabLabel = "Tab \(tabIndex)"
        }
        return "\(session.title) › Pane \(paneIndex) › \(tabLabel)"
    }
}

private struct BellFeedRow: View {
    let entry: BellFeedEntry
    let path: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(entry.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                if let message = entry.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
