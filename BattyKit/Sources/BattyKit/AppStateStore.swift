// AppStateStore.swift

import Foundation
import Observation

@Observable
public final class AppStateStore {
    public private(set) var sessions: [SessionRuntime]
    public var selectedSessionID: UUID?

    public init(sessions: [SessionRuntime] = []) {
        if sessions.isEmpty {
            let initial = SessionRuntime(title: "Session 1")
            self.sessions = [initial]
            self.selectedSessionID = initial.id
        } else {
            self.sessions = sessions
            self.selectedSessionID = sessions.first?.id
        }
    }

    public var selectedSession: SessionRuntime? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    @discardableResult
    public func addSession(title: String? = nil) -> SessionRuntime {
        let resolvedTitle = title ?? "Session \(sessions.count + 1)"
        let session = SessionRuntime(title: resolvedTitle)
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    public func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
        if sessions.isEmpty {
            addSession()
        }
    }

    public func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
    }

    public func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }
}
