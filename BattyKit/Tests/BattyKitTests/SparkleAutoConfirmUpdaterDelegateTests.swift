// SparkleAutoConfirmUpdaterDelegateTests.swift

import Foundation
import OSLog
import Sparkle
import Testing
@testable import BattyKit

@MainActor
struct SparkleAutoConfirmUpdaterDelegateTests {
    private final class LogBox {
        var lines: [String] = []
    }

    private func makeDelegate() -> (SparkleAutoConfirmUpdaterDelegate, LogBox) {
        let box = LogBox()
        return (SparkleAutoConfirmUpdaterDelegate(log: { _, line in box.lines.append(line) }), box)
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
