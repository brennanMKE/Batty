// SessionRuntime.swift

import Foundation
import Observation

@Observable
public final class SessionRuntime: Identifiable {
    public let id: UUID
    public var title: String
    public let pane: PaneRuntime

    public init(id: UUID = UUID(), title: String = "Session", pane: PaneRuntime? = nil) {
        self.id = id
        self.title = title
        self.pane = pane ?? PaneRuntime()
    }
}
