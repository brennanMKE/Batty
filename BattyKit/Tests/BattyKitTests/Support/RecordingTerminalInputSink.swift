// RecordingTerminalInputSink.swift

import Foundation
@testable import BattyKit

@MainActor
final class RecordingTerminalInputSink: TerminalInputSink {
    enum Event: Equatable {
        case paste(String)
        case pressReturn
    }

    private(set) var events: [Event] = []
    /// The Tabs the sink factory was asked for, in order.
    var tabIDs: [UUID] = []

    func paste(text: String) -> Bool {
        events.append(.paste(text))
        return true
    }

    func pressReturn() -> Bool {
        events.append(.pressReturn)
        return true
    }
}

/// Runs `body` with `ExitDispatcher.inputSink` swapped for a recorder and
/// returns what Exit Shell pasted and pressed.
@MainActor
func recordingExitShell(_ body: () -> Void) -> RecordingTerminalInputSink {
    let recorder = RecordingTerminalInputSink()
    let saved = ExitDispatcher.inputSink
    defer { ExitDispatcher.inputSink = saved }
    ExitDispatcher.inputSink = { tab in
        recorder.tabIDs.append(tab.id)
        return recorder
    }
    body()
    return recorder
}
