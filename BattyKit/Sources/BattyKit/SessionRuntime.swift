// SessionRuntime.swift

import Foundation
import Observation

@Observable
public final class SessionRuntime: Identifiable {
    public let id: UUID
    public var title: String
    public let terminal: TerminalViewState

    public init(id: UUID = UUID(), title: String = "Session", terminal: TerminalViewState? = nil) {
        self.id = id
        self.title = title
        self.terminal = terminal ?? TerminalViewState()
    }
}
