// TabRuntime.swift

import Foundation
import Observation

@Observable
public final class TabRuntime: Identifiable {
    public let id: UUID
    public var titleOverride: String?
    public let terminal: TerminalViewState

    public internal(set) var bellCount: Int = 0
    public internal(set) var unseenBellCount: Int = 0
    public internal(set) var lastBellAt: Date?
    public internal(set) var lastBellMessage: String?

    @ObservationIgnored
    private var lastObservedBellCount: Int = 0
    @ObservationIgnored
    private var lastObservedNotificationAt: Date?

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        bellCount: Int = 0,
        unseenBellCount: Int = 0,
        lastBellAt: Date? = nil,
        lastBellMessage: String? = nil
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.terminal = TerminalViewState(theme: Self.activeTheme())
        if let workingDirectory {
            self.terminal.configuration.workingDirectory = workingDirectory
        }
        self.bellCount = bellCount
        self.unseenBellCount = unseenBellCount
        self.lastBellAt = lastBellAt
        self.lastBellMessage = lastBellMessage
    }

    public func recordBellTickIfNeeded() {
        let observed = terminal.bellCount
        guard observed > lastObservedBellCount else { return }
        let delta = observed - lastObservedBellCount
        lastObservedBellCount = observed
        bellCount += delta
        unseenBellCount += delta
        lastBellAt = terminal.lastBellAt ?? Date()
        lastBellMessage = nil
    }

    public func recordDesktopNotificationIfNeeded() {
        guard let at = terminal.lastDesktopNotificationAt else { return }
        guard at != lastObservedNotificationAt else { return }
        lastObservedNotificationAt = at
        bellCount += 1
        unseenBellCount += 1
        lastBellAt = at
        lastBellMessage = Self.formatNotification(
            title: terminal.lastDesktopNotificationTitle,
            body: terminal.lastDesktopNotificationBody
        )
    }

    public func markBellsSeen() {
        unseenBellCount = 0
    }

    private static func formatNotification(title: String?, body: String?) -> String? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedTitle?.isEmpty == false ? trimmedTitle : nil,
                trimmedBody?.isEmpty == false ? trimmedBody : nil) {
        case let (title?, body?):
            return "\(title): \(body)"
        case let (title?, nil):
            return title
        case let (nil, body?):
            return body
        default:
            return nil
        }
    }

    private static func activeTheme() -> TerminalTheme {
        guard
            let name = UserDefaults.standard.string(forKey: ThemePreference.defaultsKey),
            !name.isEmpty,
            let definition = GhosttyThemeCatalog.theme(named: name)
        else {
            return .default
        }
        return definition.toTerminalTheme()
    }
}
