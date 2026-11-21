// PhotonSettingsModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct PhotonSettingsModelTests {
    final class Counters {
        var locates = 0
        var opened: [String] = []
        var found: URL?
        var tab: TabRuntime?
    }

    private func model(_ counters: Counters) -> PhotonSettingsModel {
        PhotonSettingsModel(
            locate: { counters.locates += 1; return counters.found },
            openInstallPane: { counters.opened.append($0); return counters.tab })
    }

    @Test func initRunsNeitherDetectionNorInstall() {
        let counters = Counters()
        let model = model(counters)
        #expect(counters.locates == 0)
        #expect(counters.opened.isEmpty)
        #expect(model.state == .checking)
    }

    @Test func refreshReportsInstalledPath() async {
        let counters = Counters()
        counters.found = URL(fileURLWithPath: "/usr/local/bin/photon")
        let model = model(counters)
        await model.refresh()
        #expect(model.state == .installed("/usr/local/bin/photon"))
    }

    @Test func refreshReportsNotInstalled() async {
        let counters = Counters()
        let model = model(counters)
        await model.refresh()
        #expect(model.state == .notInstalled)
    }

    @Test func installOpensAPaneWithExactlyTheDocumentedCommand() {
        let counters = Counters()
        counters.tab = TabRuntime(workingDirectory: "/tmp")
        let model = model(counters)
        model.install()
        #expect(counters.opened == [PhotonInstall.command])
        #expect(model.installError == nil)
        #expect(counters.locates == 0)
    }

    @Test func installWithNoWindowShowsAnError() {
        let counters = Counters()
        let model = model(counters)
        model.install()
        #expect(counters.opened.count == 1)
        #expect(model.installError != nil)
    }

    @Test func installerExitTriggersRedetection() async throws {
        let counters = Counters()
        let tab = TabRuntime(workingDirectory: "/tmp")
        counters.tab = tab
        let model = model(counters)
        await model.refresh()
        #expect(model.state == .notInstalled)
        model.install()
        counters.found = URL(fileURLWithPath: "/usr/local/bin/photon")
        tab.notifyCommandFinishedObservers(exitCode: 0, durationNanos: 0)
        try await #require(model.pendingRefresh).value
        #expect(model.state == .installed("/usr/local/bin/photon"))
        let first = model.pendingRefresh
        tab.notifyCommandFinishedObservers(exitCode: 0, durationNanos: 0)
        #expect(model.pendingRefresh == first)
    }
}
