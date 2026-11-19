// PendingClipboardConfirmationTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct PendingClipboardConfirmationTests {
    @Test func messageNamesKindSessionPaneAndProgram() {
        let context = ClipboardRequestContext(sessionTitle: "Agents", tabID: UUID(), paneIndex: 2, tabLabel: "zsh", processName: "nvim")
        let message = PendingClipboardConfirmation.message(kind: .osc52Read, context: context)
        #expect(message == "\u{201C}nvim\u{201D} in \u{201C}Agents\u{201D} \u{203A} Pane 2 \u{203A} zsh wants to read the clipboard.")
    }

    @Test func messageFallsBackWithoutProgram() {
        let context = ClipboardRequestContext(sessionTitle: "Agents", tabID: UUID(), paneIndex: 1)
        let message = PendingClipboardConfirmation.message(kind: .osc52Write, context: context)
        #expect(message == "A program in \u{201C}Agents\u{201D} \u{203A} Pane 1 wants to write to the clipboard.")
    }

    @Test func messageWithoutContextIsGeneric() {
        #expect(PendingClipboardConfirmation.message(kind: .osc52Read, context: nil) == "A terminal program wants to read the clipboard.")
        #expect(PendingClipboardConfirmation.message(kind: .osc52Read, context: .unresolved(tabID: UUID())) == "A terminal program wants to read the clipboard.")
    }
}
