// ThemePairTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ThemePairTests {
    private func decode(_ object: [String: Any]) throws -> ThemePair {
        try JSONDecoder().decode(ThemePair.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func emptySlotsNormalizeToNil() {
        let pair = ThemePair(dark: "  ", light: " Nord ")
        #expect(pair.dark == nil)
        #expect(pair.light == "Nord")
    }

    @Test func bothNilIsNoTheme() {
        #expect(ThemePair(dark: nil, light: "").normalized == nil)
        #expect(ThemePair(dark: nil, light: nil).isEmpty)
        #expect(ThemePair.both("Nord").normalized == .both("Nord"))
    }

    @Test func slotForAppearance() {
        let pair = ThemePair(dark: "A", light: "B")
        #expect(pair.name(isDark: true) == "A")
        #expect(pair.name(isDark: false) == "B")
        #expect(pair.with(nil, isDark: true) == ThemePair(dark: nil, light: "B"))
    }

    @Test func unknownNameRoundTripsVerbatim() throws {
        let pair = ThemePair(dark: "No Such Theme 9000", light: nil)
        let data = try JSONEncoder().encode(pair)
        #expect(String(decoding: data, as: UTF8.self) == #"{"dark":"No Such Theme 9000"}"#)
        #expect(try JSONDecoder().decode(ThemePair.self, from: data) == pair)
    }

    @Test func wrongTypeSlotDecodesNilAndKeepsTheOther() throws {
        let pair = try decode(["dark": 42, "light": "Nord"])
        #expect(pair == ThemePair(dark: nil, light: "Nord"))
    }

    @Test func overlongOrControlCharacterNameDecodesNil() throws {
        #expect(try decode(["dark": String(repeating: "x", count: 129), "light": "ok"]) == ThemePair(dark: nil, light: "ok"))
        #expect(try decode(["dark": "bad\u{7}name"]).dark == nil)
        #expect(try decode(["dark": String(repeating: "x", count: 128)]).dark?.count == 128)
    }
}
