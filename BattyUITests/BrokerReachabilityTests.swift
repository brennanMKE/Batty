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

    private struct CLIResult {
        var status: Int32
        var output: String
    }

    private struct StatusJSON: Decodable {
        struct Status: Decodable {
            var bundlePath: String
            var windowCount: Int
        }
        var state: String
        var status: Status?
    }

    /// The runner lives at `<Products>/BattyUITests-Runner.app/...`, beside the
    /// app under test, so the bundle is the first ancestor directory that
    /// contains `Batty Beta.app`. Skips when it is not there, which is also how
    /// a build without the relay-bearing runner shows up.
    private func appUnderTest() throws -> URL {
        var dir = Bundle(for: BrokerReachabilityTests.self).bundleURL
        while dir.path != "/" {
            dir.deleteLastPathComponent()
            let app = dir.appending(path: "Batty Beta.app")
            if FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/Resources/bin/batty").path) {
                return app
            }
        }
        throw XCTSkip("app under test not found beside the test runner")
    }

    /// The runner is App Sandboxed and its children inherit that, so the CLI
    /// cannot mach-lookup the broker from here. `tools/vm-guest-broker.sh`
    /// installs a guest-only loopback relay that runs the embedded CLI outside
    /// the sandbox; this sends it one line of tab-separated arguments through `nc`. The line
    /// is split on tabs by the relay, so an argument cannot contain one.
    private func relay(_ arguments: [String]) -> CLIResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/nc")
        process.arguments = ["127.0.0.1", "47911"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return CLIResult(status: -1, output: "\(error)") }
        input.fileHandleForWriting.write(Data((arguments.joined(separator: "\t") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let range = text.range(of: "__EXIT__ ", options: .backwards),
              let status = Int32(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return CLIResult(status: -1, output: "no relay reply (nc exit \(process.terminationStatus)): \(text)") }
        return CLIResult(status: status, output: String(text[..<range.lowerBound]))
    }

    private func decodeStatus(_ output: String) -> StatusJSON? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(StatusJSON.self, from: Data(output[open...close].utf8))
    }

    @MainActor
    func testPingStatusAndListReachTheLaunchedApp() throws {
        let appURL = try appUnderTest()
        let app = BattyUITestHarness.launchBatty()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let ping = relay(["ping"])
        XCTAssertEqual(ping.status, 0, "ping exit \(ping.status): \(ping.output)")

        // The app registers its endpoint with the broker asynchronously after
        // launch, so `status` is the first verb that needs the wait.
        var last = CLIResult(status: -1, output: "")
        let reached = waitFor({ last = self.relay(["status", "--json"]); return last.status == 0 }, timeout: 30)
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

        let list = relay(["list"])
        XCTAssertEqual(list.status, 0, "list exit \(list.status): \(list.output)")
    }
}
