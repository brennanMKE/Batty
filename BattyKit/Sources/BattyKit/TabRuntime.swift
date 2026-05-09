// TabRuntime.swift

import Foundation
import Observation

@Observable
public final class TabRuntime: Identifiable {
    public let id: UUID
    public var titleOverride: String?
    public let terminal: TerminalViewState

    public init(id: UUID = UUID(), titleOverride: String? = nil) {
        self.id = id
        self.titleOverride = titleOverride
        self.terminal = TerminalViewState()
    }
}
