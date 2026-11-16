// ReadStateHeaderActions.swift

import SwiftUI

/// The Mark All Read and Clear Read buttons in a notification list's header.
struct ReadStateHeaderActions: View {
    let unreadCount: Int
    let readCount: Int
    let identifierPrefix: String
    let markAllRead: () -> Void
    let clearRead: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if unreadCount > 0 {
                Button("Mark All Read", action: markAllRead)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).mark-all-read")
            }
            if readCount > 0 {
                Button("Clear Read", action: clearRead)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).clear-read")
            }
        }
    }

    static func selection(_ current: UUID?, afterRemovalIn remaining: [UUID]) -> UUID? {
        if let current, remaining.contains(current) { return current }
        return remaining.first
    }
}
