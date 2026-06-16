// AppearanceObserver.swift

import AppKit
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppearanceObserver")

/// Observes `NSApp.effectiveAppearance` via KVO and re-applies the global
/// theme for the new appearance whenever the user switches between Dark and
/// Light. The write (`applyGlobalThemeForCurrentAppearance`) is sourced from
/// an AppKit KVO callback — event-origin, not layout/geometry-origin — so it
/// is safe under the `docs/swiftui-observation-rules.md` rules.
public final class AppearanceObserver: NSObject {
    private let store: AppStateStore
    @ObservationIgnored private var observation: NSKeyValueObservation?

    public init(store: AppStateStore) {
        self.store = store
        super.init()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            logger.info("effectiveAppearance changed")
            self.store.applyGlobalThemeForCurrentAppearance()
        }
    }

    deinit {
        observation?.invalidate()
    }
}
