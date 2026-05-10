// TabRuntime.swift

import Foundation
import Observation

@Observable
public final class TabRuntime: Identifiable {
    public let id: UUID
    public var titleOverride: String?
    public let terminal: TerminalViewState

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.terminal = TerminalViewState(theme: Self.activeTheme())
        if let workingDirectory {
            self.terminal.configuration.workingDirectory = workingDirectory
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
