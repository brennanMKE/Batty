// AppWideBackgroundGate.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppWideBackgroundGate")

nonisolated public enum BackgroundImageState: Equatable, Sendable {
    case none
    case usable
    case missing
    case rejected
}

/// The only route from the persisted background keys to a config builder. A
/// persisted file reaches libghostty only after proving it is the importer's
/// unchanged output, because a corrupt file leaves a Pane with no shell and an
/// oversized one aborts the process (#0374's measurements). With the feature
/// flag off nothing here reads `UserDefaults` or the disk.
///
/// Not `@Observable`, so the memo written during a read invalidates no view.
public final class AppWideBackgroundGate {
    public static let live = make(
        flags: .resolved(),
        defaults: .standard,
        directory: TerminalBackgroundImageImporter.appWideDirectory()
    )

    static func make(flags: FeatureFlags, defaults: UserDefaults, directory: URL) -> AppWideBackgroundGate {
        AppWideBackgroundGate(defaults: defaults, isEnabled: flags.terminalBackgrounds) { path in
            TerminalBackgroundImageImporter.inspect(path: path, directory: directory)
        }
    }

    let defaults: UserDefaults
    let isEnabled: Bool
    private let inspectImage: (String) -> BackgroundImageState
    private var memo: (path: String, state: BackgroundImageState)?

    init(defaults: UserDefaults, isEnabled: Bool, inspectImage: @escaping (String) -> BackgroundImageState) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.inspectImage = inspectImage
    }

    /// What builders get: the stored settings without an image that failed
    /// inspection. Hashes the file only when the path differs from the memo.
    func settings() -> TerminalBackgroundSettings {
        guard isEnabled else { return .off }
        let stored = SettingsPreference.resolvedBackground(defaults: defaults)
        guard let path = stored.imagePath else { return stored }
        return state(forPath: path) == .usable ? stored : stored.withImagePath(nil)
    }

    /// What Settings shows, including an image that failed inspection, so it
    /// can name the problem.
    func storedSettings() -> TerminalBackgroundSettings {
        guard isEnabled else { return .off }
        return SettingsPreference.resolvedBackground(defaults: defaults)
    }

    /// Inspects the stored image again, for a file that changed on disk.
    @discardableResult
    func refreshImageState() -> BackgroundImageState {
        memo = nil
        guard isEnabled, let path = storedSettings().imagePath else { return .none }
        return state(forPath: path)
    }

    private func state(forPath path: String) -> BackgroundImageState {
        if let memo, memo.path == path { return memo.state }
        let state = inspectImage(path)
        memo = (path, state)
        if state != .usable {
            logger.error("app-wide background image not used (\(String(describing: state), privacy: .public)): \(path, privacy: .private)")
        }
        return state
    }
}
