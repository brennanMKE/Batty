// ProcessIdentifierFormattingTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ProcessIdentifierFormattingTests {

    @Test func fourDigitPIDHasNoGroupingSeparator() {
        #expect(ProcessIdentifierFormatting.identifier(pid_t(6044)) == "6044")
    }

    @Test func fiveDigitPIDHasNoGroupingSeparator() {
        #expect(ProcessIdentifierFormatting.identifier(pid_t(61877)) == "61877")
    }

    @Test func fileDescriptorNumberHasNoGroupingSeparator() {
        #expect(ProcessIdentifierFormatting.identifier(Int32(10240)) == "10240")
    }

    @Test func outputDiffersFromLocaleFormattedNumber() {
        let german = Locale(identifier: "de_DE")
        let grouped = 6044.formatted(.number.locale(german))
        #expect(grouped != "6044")
        #expect(ProcessIdentifierFormatting.identifier(6044) == "6044")
    }
}
