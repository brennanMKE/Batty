// AppearanceObserver.swift

import AppKit
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppearanceObserver")

/// Observes `NSApp.effectiveAppearance` via KVO and re-applies the global
/// theme for the new appearance whenever the user switches between Dark and
/// Light. The write (`applyGlobalThemeForCurrentAppearance`) is sourced from
/// an AppKit KVO callback — event-origin, not layout/geometry-origin — so it
/// is safe under the `docs/swiftui-observation-rules.md` rules.
///
/// Isolation (#0320): `NSObjectProtocol.observe(_:options:changeHandler:)`
/// is not concurrency-audited, so its `changeHandler` closure type carries
/// no actor annotation and the compiler infers the closure body as running
/// in a nonisolated context — hence the warning on calling the main-actor
/// `applyGlobalThemeForCurrentAppearance()` from here. That inference is a
/// gap in the API's Swift 6 annotations, not a real possibility of this
/// closure firing off the main thread: KVO delivers change notifications
/// synchronously on whatever thread mutates the observed property, and
/// `NSApplication.effectiveAppearance` is AppKit UI state that only ever
/// changes on the main thread (AppKit is main-thread-affine; there is no
/// supported way to flip system appearance from a background thread).
/// `MainActor.assumeIsolated` asserts that invariant with a runtime check —
/// it traps immediately if the assumption is ever wrong, rather than
/// silently racing — which is the documented, defensible way to bridge a
/// non-isolated but main-thread-only callback into main-actor code.
public final class AppearanceObserver: NSObject {
    private let store: AppStateStore
    @ObservationIgnored private var observation: NSKeyValueObservation?

    public init(store: AppStateStore) {
        self.store = store
        super.init()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            logger.info("effectiveAppearance changed")
            MainActor.assumeIsolated {
                self.store.applyGlobalThemeForCurrentAppearance()
            }
        }
    }

    deinit {
        observation?.invalidate()
    }
}
