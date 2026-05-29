// PaneViewTruncateTests.swift

import Foundation
import Testing
@testable import BattyKit

struct PaneViewTruncateTests {

    @Test func shortTitleIsUntouched() {
        #expect(PaneView.truncate("Tab", limit: 24) == "Tab")
    }

    @Test func longTitleGetsMiddleEllipsis() {
        let title = "brennan@macbook-air-m4-brennan-2:~/Developer/brennanMKE/Batty"
        let result = PaneView.truncate(title, limit: 24)
        #expect(result.count == 24)
        #expect(result.contains("…"))
    }

    @Test func exactlyAtLimitIsUntouched() {
        let title = String(repeating: "x", count: 24)
        #expect(PaneView.truncate(title, limit: 24) == title)
    }
}
