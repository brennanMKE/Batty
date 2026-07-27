// BattyContextEnvironmentTests.swift

import Foundation
import Testing
@testable import BattyKit

struct BattyContextEnvironmentTests {

    @Test func lookupReturnsAbsentWhenKeyMissing() {
        let result = BattyContextEnvironment.lookup(.sessionID, in: [:])
        #expect(result == .absent)
    }

    @Test func lookupReturnsAbsentWhenValueIsEmptyString() {
        let result = BattyContextEnvironment.lookup(.sessionID, in: ["BATTY_SESSION_ID": ""])
        #expect(result == .absent)
    }

    @Test func lookupReturnsMalformedForNonUUIDValue() {
        let result = BattyContextEnvironment.lookup(.paneID, in: ["BATTY_PANE_ID": "not-a-uuid"])
        #expect(result == .malformed("not-a-uuid"))
    }

    @Test func lookupReturnsValueForWellFormedUUID() {
        let uuid = UUID()
        let result = BattyContextEnvironment.lookup(.tabID, in: ["BATTY_TAB_ID": uuid.uuidString])
        #expect(result == .value(uuid))
    }

    @Test func lookupIgnoresOtherKeysInEnvironment() {
        let uuid = UUID()
        let env = ["BATTY_PANE_ID": uuid.uuidString, "BATTY_SESSION_ID": "garbage", "PATH": "/usr/bin"]
        #expect(BattyContextEnvironment.lookup(.paneID, in: env) == .value(uuid))
        #expect(BattyContextEnvironment.lookup(.sessionID, in: env) == .malformed("garbage"))
        #expect(BattyContextEnvironment.lookup(.tabID, in: env) == .absent)
    }
}
