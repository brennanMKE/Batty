// PortablePathTests.swift

import Testing
@testable import BattyKit

struct PortablePathTests {
    private let home = "/Users/brennan"

    @Test func aRootUnderHomeBecomesHomeRelative() {
        #expect(PortablePath.encode(absolute: "/Users/brennan/Developer/Batty", home: home) == "~/Developer/Batty")
    }

    @Test func homeItselfBecomesATilde() {
        #expect(PortablePath.encode(absolute: "/Users/brennan", home: home) == "~")
    }

    @Test func aRootOutsideHomeIsUnchanged() {
        #expect(PortablePath.encode(absolute: "/Volumes/Work/x", home: home) == "/Volumes/Work/x")
        #expect(PortablePath.encode(absolute: "/opt/x", home: home) == "/opt/x")
    }

    @Test func aPrefixThatOnlySharesTheHomeStringIsNotRewritten() {
        #expect(PortablePath.encode(absolute: "/Users/brennan2/x", home: home) == "/Users/brennan2/x")
    }

    @Test func aTrailingSlashOnHomeIsTolerated() {
        #expect(PortablePath.encode(absolute: "/Users/brennan/x", home: "/Users/brennan/") == "~/x")
    }

    @Test func decodeUsesTheGivenHome() {
        #expect(PortablePath.decode(portable: "~/Developer/Batty", home: "/Users/other") == "/Users/other/Developer/Batty")
        #expect(PortablePath.decode(portable: "~", home: "/Users/other") == "/Users/other")
        #expect(PortablePath.decode(portable: "/Volumes/Work/x", home: "/Users/other") == "/Volumes/Work/x")
    }

    @Test func aTildeUserFormIsNotExpanded() {
        #expect(PortablePath.decode(portable: "~root/x", home: home) == "~root/x")
        #expect(PortablePath.decode(portable: "~brennan", home: home) == "~brennan")
    }

    @Test(arguments: [
        "/Users/brennan/Developer/Batty", "/Users/brennan", "/Volumes/Work/x", "/opt/x", "/Users/brennan2/x",
    ])
    func encodeThenDecodeRoundTrips(path: String) {
        #expect(PortablePath.decode(portable: PortablePath.encode(absolute: path, home: home), home: home) == path)
    }

    @Test func aRootEncodedOnOneMacDecodesUnderAnothersHome() {
        let portable = PortablePath.encode(absolute: "/Users/brennan/Developer/Batty", home: home)
        #expect(PortablePath.decode(portable: portable, home: "/Users/guest") == "/Users/guest/Developer/Batty")
    }
}
