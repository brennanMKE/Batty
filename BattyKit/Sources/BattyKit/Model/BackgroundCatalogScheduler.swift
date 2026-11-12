// BackgroundCatalogScheduler.swift

import Foundation

/// Checks catalogs 30 s after launch and then once a day, one at a time. The
/// automatic-checks setting is read on every tick, so turning it off needs no
/// observer.
@MainActor
final class BackgroundCatalogScheduler {
    static let launchDelay: Duration = .seconds(30)
    static let interval: Duration = .seconds(24 * 60 * 60)

    private let hosted: HostedBackgroundsModel
    private let clock: SchedulingClock
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(hosted: HostedBackgroundsModel, clock: SchedulingClock, defaults: UserDefaults) {
        self.hosted = hosted
        self.clock = clock
        self.defaults = defaults
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, clock] in
            await clock.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.runScheduledChecks()
                await clock.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func runScheduledChecks() async {
        guard SettingsPreference.resolvedBackgroundCatalogsAutoCheck(defaults: defaults) else { return }
        for url in hosted.scheduledCatalogURLs {
            if Task.isCancelled { return }
            await hosted.refresh(url)
        }
    }
}
