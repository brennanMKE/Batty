// ServerStatSparklineTests.swift

import CoreGraphics
import Testing
@testable import BattyKit

@MainActor
struct ServerStatSparklineTests {
    private let rect = CGRect(x: 0, y: 0, width: 100, height: 10)

    @Test func normalizesIntoTheRect() {
        let points = ServerStatSparkline.points(values: [1, 3, 2], in: rect)
        #expect(points == [CGPoint(x: 0, y: 10), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 5)])
    }

    @Test func flatSeriesDrawsAMidline() {
        #expect(ServerStatSparkline.points(values: [4, 4, 4], in: rect).allSatisfy { $0.y == 5 })
    }

    @Test func singleSampleDrawsNothing() {
        #expect(ServerStatSparkline.points(values: [4], in: rect).isEmpty)
    }
}

struct ServerPaneViewStateTests {
    @Test func stateChipTextForEveryState() {
        #expect(ServerPaneDisplay.stateText(.starting, isResponding: nil, attach: false) == "Starting")
        #expect(ServerPaneDisplay.stateText(.starting, isResponding: nil, attach: true) == "Not listening")
        #expect(ServerPaneDisplay.stateText(.listening(pid: 1), isResponding: true, attach: false) == "Listening")
        #expect(ServerPaneDisplay.stateText(.listening(pid: nil), isResponding: true, attach: true) == "Listening, owned by another user")
        #expect(ServerPaneDisplay.stateText(.listening(pid: 1), isResponding: false, attach: false) == "Not responding")
        #expect(ServerPaneDisplay.stateText(.stopping, isResponding: nil, attach: false) == "Stopping")
        #expect(ServerPaneDisplay.stateText(.stopped(exitCode: 130, reason: .requested), isResponding: nil, attach: false) == "Stopped")
        #expect(ServerPaneDisplay.stateText(.stopped(exitCode: nil, reason: .terminalClosed), isResponding: nil, attach: false) == "Stopped, terminal closed")
        #expect(ServerPaneDisplay.stateText(.crashed(exitCode: 0), isResponding: nil, attach: false) == "Exited (0)")
        #expect(ServerPaneDisplay.stateText(.crashed(exitCode: 1), isResponding: nil, attach: false) == "Crashed (1)")
        #expect(ServerPaneDisplay.stateText(.crashed(exitCode: nil), isResponding: nil, attach: false) == "Crashed")
    }

    @Test func restartHiddenWithoutCapability() {
        #expect(!ServerPaneDisplay.showsRestart(canRestart: false))
        #expect(ServerPaneDisplay.showsRestart(canRestart: true))
    }

    @Test func stopHiddenForAnotherUsersListener() {
        #expect(!ServerPaneDisplay.showsStop(.listening(pid: nil), canStop: true))
        #expect(ServerPaneDisplay.showsStop(.listening(pid: 10), canStop: true))
    }
}
