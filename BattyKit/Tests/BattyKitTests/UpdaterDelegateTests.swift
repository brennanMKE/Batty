// UpdaterDelegateTests.swift

import Foundation
import OSLog
import Sparkle
import Testing
@testable import BattyKit

@MainActor
struct UpdaterDelegateTests {
    private final class LogBox {
        var lines: [String] = []
    }

    private func makeDelegate(
        refusesBackgroundChecks: Bool = true,
        preconfirmedQuit: PreconfirmedQuit = PreconfirmedQuit()
    ) -> (UpdaterDelegate, LogBox) {
        let box = LogBox()
        let delegate = UpdaterDelegate(
            preconfirmedQuit: preconfirmedQuit,
            refusesBackgroundChecks: refusesBackgroundChecks,
            log: { _, line in box.lines.append(line) }
        )
        return (delegate, box)
    }

    private func makeUpdater() -> SPUUpdater {
        SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: nil)
    }

    @Test func standardDelegateAllowsEveryCheck() throws {
        let (delegate, box) = makeDelegate(refusesBackgroundChecks: false)
        try delegate.decide(.updatesInBackground)
        try delegate.decide(.updateInformation)
        try delegate.decide(.updates)
        #expect(box.lines.isEmpty)
    }

    @Test func willInstallUpdateMarksTheQuit() {
        let quit = PreconfirmedQuit()
        let (delegate, _) = makeDelegate(preconfirmedQuit: quit)
        delegate.updater(makeUpdater(), willInstallUpdate: SUAppcastItem.empty())
        #expect(quit.pending == .sparkleInstall)
    }

    @Test func abortClearsTheMark() {
        let quit = PreconfirmedQuit()
        quit.mark(.sparkleInstall)
        let (delegate, _) = makeDelegate(preconfirmedQuit: quit)
        delegate.updater(makeUpdater(), didAbortWithError: NSError(domain: "test", code: 1))
        #expect(quit.pending == nil)
    }

    @Test func backgroundCheckIsRefusedAndLogged() {
        let (delegate, box) = makeDelegate()
        #expect(throws: (any Error).self) { try delegate.decide(.updatesInBackground) }
        #expect(box.lines == ["sparkle-auto: background check refused"])
    }

    @Test func informationCheckIsRefused() {
        let (delegate, _) = makeDelegate()
        #expect(throws: (any Error).self) { try delegate.decide(.updateInformation) }
    }

    @Test func hookCheckIsAllowedSilently() throws {
        let (delegate, box) = makeDelegate()
        try delegate.decide(.updates)
        #expect(box.lines.isEmpty)
    }

    @Test func refusalIsNotSparklesNoUpdateError() {
        let (delegate, _) = makeDelegate()
        do {
            try delegate.decide(.updatesInBackground)
            Issue.record("expected a throw")
        } catch {
            let ns = error as NSError
            #expect(ns.domain != SUSparkleErrorDomain)
            #expect(ns.localizedDescription == SparkleAutoConfirm.refusalErrorDescription)
        }
    }
}
