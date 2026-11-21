// PhotonSettingsModel.swift

import Foundation
import Observation

/// Settings ▸ General ▸ Servers' PhotonHTTP row (#0693). Detects `photon`
/// only when asked, and runs the installer only from the button.
@MainActor
@Observable
public final class PhotonSettingsModel {
    public enum State: Equatable {
        case checking
        case installed(String)
        case notInstalled
    }

    public private(set) var state: State = .checking
    public private(set) var installError: String?

    @ObservationIgnored private let locate: @MainActor () async -> URL?
    @ObservationIgnored private let openInstallPane: @MainActor (String) -> TabRuntime?
    /// The re-detection the installer's exit started; tests await it.
    @ObservationIgnored private(set) var pendingRefresh: Task<Void, Never>?

    public init(locate: @escaping @MainActor () async -> URL?, openInstallPane: @escaping @MainActor (String) -> TabRuntime?) {
        self.locate = locate
        self.openInstallPane = openInstallPane
    }

    public convenience init(store: AppStateStore) {
        self.init(
            locate: { [weak store] in await store?.locatePhoton(nil) },
            openInstallPane: { [weak store] command in store?.openPhotonInstallPane(command: command) }
        )
    }

    public func refresh() async {
        if state != .checking { state = .checking }
        let found = await locate()
        let next: State = found.map { .installed($0.path) } ?? .notInstalled
        if state != next { state = next }
    }

    /// Event origin only (the Install PhotonHTTP… button).
    public func install() {
        guard let tab = openInstallPane(PhotonInstall.command) else {
            installError = String(localized: "Open a Batty window first.", comment: "Settings: Install PhotonHTTP needs a window to open its terminal Pane in")
            return
        }
        if installError != nil { installError = nil }
        var observerID: UUID?
        observerID = tab.addCommandFinishedObserver { [weak self, weak tab] _ in
            if let observerID { tab?.removeCommandFinishedObserver(observerID) }
            guard let self else { return }
            self.pendingRefresh = Task { await self.refresh() }
        }
    }
}
