// BrokerReachabilityTests.swift

import XCTest

/// Proves the guest's launched app is reachable through the embedded CLI and
/// the broker (#0419), the precondition for every CLI-driven UI test (#0413).
/// `tools/vm-guest-broker.sh` starts the broker and the CLI relay before this
/// runs.
nonisolated final class BrokerReachabilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        BattyUITestHarness.sweepSentinels()
    }

    override func tearDownWithError() throws {
        BattyUITestHarness.sweepSentinels()
    }

    private struct StatusJSON: Decodable {
        struct Status: Decodable {
            var bundlePath: String
            var windowCount: Int
        }
        var state: String
        var status: Status?
    }

    private func decodeStatus(_ output: String) -> StatusJSON? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(StatusJSON.self, from: Data(output[open...close].utf8))
    }

    @MainActor
    func testPingStatusAndListReachTheLaunchedApp() throws {
        let appURL: URL
        do { appURL = try BattyCLI.appBundleURL(from: BrokerReachabilityTests.self) } catch { throw XCTSkip("app under test not found beside the test runner") }
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let ping = BattyCLI.run(["ping"])
        XCTAssertEqual(ping.status, 0, "ping exit \(ping.status): \(ping.output)")

        // The app registers its endpoint with the broker asynchronously after
        // launch, so `status` is the first verb that needs the wait.
        var last = CLIResult(status: -1, output: "")
        let reached = waitFor({ last = BattyCLI.run(["status", "--json"]); return last.status == 0 }, timeout: 30)
        XCTAssertTrue(reached, "status exit \(last.status): \(last.output)")

        let status = try XCTUnwrap(decodeStatus(last.output), "status --json was not JSON: \(last.output)")
        XCTAssertEqual(status.state, "ok")
        let payload = try XCTUnwrap(status.status, "status --json carried no status: \(last.output)")
        XCTAssertGreaterThanOrEqual(payload.windowCount, 1)
        XCTAssertEqual(
            URL(filePath: payload.bundlePath).standardizedFileURL.path,
            appURL.standardizedFileURL.path,
            "the CLI answered from a different app than the one XCUITest launched"
        )

        let list = BattyCLI.run(["list"])
        XCTAssertEqual(list.status, 0, "list exit \(list.status): \(list.output)")
    }
}
