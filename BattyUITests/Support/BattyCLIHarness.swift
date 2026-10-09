// BattyCLIHarness.swift

import Foundation
import XCTest

nonisolated struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

nonisolated struct CLIResult {
    var status: Int32
    var output: String

    var lines: [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lines that are exactly one UUID, in order. `batty new` and `pane split`
    /// print ids this way; the relay merges stderr into the output, so the
    /// notes the CLI writes there never parse as ids.
    var ids: [UUID] { lines.compactMap { UUID(uuidString: $0) } }

    var summary: String { "exit \(status): \(output)" }
}

/// `batty list --json` / `session info --json` decoded just far enough to
/// compare against the screen. Parsed with `JSONSerialization` because the
/// split tree is a recursive enum and the UI-test target does not link
/// `BattyXPCCore`.
nonisolated struct CLITopology {
    struct Pane {
        let id: UUID
        let isHidden: Bool
        let isFocused: Bool
        let kind: String
        let activeTabID: UUID
        let tabIDs: [UUID]
    }

    struct Session {
        let id: UUID
        let name: String
        let path: String?
        let isActive: Bool
        let focusedPaneID: UUID
        let panes: [Pane]

        var visiblePanes: [Pane] { panes.filter { !$0.isHidden } }
        func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }
    }

    let pid: Int32?
    let selectedSessionID: UUID?
    let sessions: [Session]

    var allPaneIDs: Set<UUID> { Set(sessions.flatMap { $0.panes.map(\.id) }) }
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }

    func session(_ id: UUID) -> Session? { sessions.first { $0.id == id } }
    func pane(_ id: UUID) -> Pane? { sessions.lazy.compactMap { $0.pane(id) }.first }
    func session(containing paneID: UUID) -> Session? { sessions.first { $0.pane(paneID) != nil } }

    init?(listOutput: String) {
        guard let object = Self.jsonObject(in: listOutput),
              let windows = object["windows"] as? [[String: Any]]
        else { return nil }
        pid = (object["pid"] as? NSNumber)?.int32Value
        selectedSessionID = windows.compactMap { ($0["selectedSessionID"] as? String).flatMap(UUID.init(uuidString:)) }.first
        sessions = windows.flatMap { ($0["sessions"] as? [[String: Any]] ?? []).compactMap(Self.parseSession) }
    }

    init?(sessionInfoOutput: String) {
        guard let object = Self.jsonObject(in: sessionInfoOutput), let session = Self.parseSession(object) else { return nil }
        pid = nil
        selectedSessionID = session.isActive ? session.id : nil
        sessions = [session]
    }

    static func jsonObject(in text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any]
    }

    private static func parseSession(_ object: [String: Any]) -> Session? {
        guard let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
              let name = object["name"] as? String,
              let focused = (object["focusedPaneID"] as? String).flatMap(UUID.init(uuidString:)),
              let root = object["root"] as? [String: Any]
        else { return nil }
        return Session(
            id: id,
            name: name,
            path: object["path"] as? String,
            isActive: object["isActive"] as? Bool ?? false,
            focusedPaneID: focused,
            panes: panes(in: root)
        )
    }

    private static func panes(in node: [String: Any]) -> [Pane] {
        if let leaf = node["leaf"] as? [String: Any], let pane = leaf["pane"] as? [String: Any] {
            return parsePane(pane).map { [$0] } ?? []
        }
        if let split = node["split"] as? [String: Any] {
            let left = (split["left"] as? [String: Any]).map(panes(in:)) ?? []
            let right = (split["right"] as? [String: Any]).map(panes(in:)) ?? []
            return left + right
        }
        return []
    }

    private static func parsePane(_ object: [String: Any]) -> Pane? {
        guard let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
              let activeTabID = (object["activeTabID"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        let tabs = (object["tabs"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
        return Pane(
            id: id,
            isHidden: object["isHidden"] as? Bool ?? false,
            isFocused: object["isFocused"] as? Bool ?? false,
            kind: object["kind"] as? String ?? "unknown",
            activeTabID: activeTabID,
            tabIDs: tabs
        )
    }
}

/// Drives the real embedded `batty` CLI against the app XCUITest launched,
/// through the guest-only relay `tools/vm-guest-broker.sh` installs (#0419):
/// the runner is App Sandboxed and a child it spawns inherits that, so a CLI
/// run from here cannot reach the broker. The relay runs the embedded CLI
/// outside the sandbox. It never carries the `BATTY_*` environment, so every
/// call must name its target with an explicit id.
nonisolated enum BattyCLI {
    static let relayHost = "127.0.0.1"
    static let relayPort = "47911"

    /// One line of tab-separated arguments in (an argument cannot contain a
    /// tab); combined output out, then a final `__EXIT__ <status>` line.
    static func run(_ arguments: [String]) -> CLIResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/nc")
        process.arguments = [relayHost, relayPort]
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

    /// Runs a verb that must succeed and returns its result.
    @discardableResult
    static func runExpectingSuccess(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) -> CLIResult {
        let result = run(arguments)
        XCTAssertEqual(result.status, 0, "batty \(arguments.joined(separator: " ")) -> \(result.summary)", file: file, line: line)
        return result
    }

    static func topology() -> CLITopology? {
        let result = run(["list", "--json"])
        guard result.status == 0 else { return nil }
        return CLITopology(listOutput: result.output)
    }

    /// Re-reads `list --json` until `predicate` holds, returning that
    /// topology, or `nil` at the bound. The bound is a hang guard; each
    /// attempt is a real round trip to the app.
    static func waitForTopology(timeout: TimeInterval = 10, _ predicate: @escaping (CLITopology) -> Bool) -> CLITopology? {
        var match: CLITopology?
        BattyUITestHarness.waitFor({
            guard let topology = topology(), predicate(topology) else { return false }
            match = topology
            return true
        }, timeout: timeout)
        return match
    }

    /// The runner lives beside the app under test in the build products, so
    /// the bundle is the first ancestor directory of the test bundle that
    /// holds `Batty Beta.app`.
    static func appBundleURL(from testClass: AnyClass) throws -> URL {
        var dir = Bundle(for: testClass).bundleURL
        while dir.path != "/" {
            dir.deleteLastPathComponent()
            let app = dir.appending(path: "Batty Beta.app")
            if FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/Resources/bin/batty").path) {
                return app
            }
        }
        throw HarnessFailure(description: "Batty Beta.app not found beside the test runner")
    }

    static func embeddedCLIPath(in appURL: URL) -> String {
        appURL.appending(path: "Contents/Resources/bin/batty").path
    }

    /// Waits for the app's endpoint to register with the broker, then pins
    /// that the CLI is talking to the process XCUITest launched (matching
    /// `status --json`'s `pid` and `bundlePath`). A wrong-process answer
    /// would make every later on-screen assertion meaningless (#0361).
    @MainActor
    static func connect(to app: XCUIApplication, from testClass: AnyClass) throws -> (appURL: URL, topology: CLITopology) {
        let appURL = try appBundleURL(from: testClass)
        var last = CLIResult(status: -1, output: "")
        let reached = BattyUITestHarness.waitFor({
            last = run(["status", "--json"])
            return last.status == 0
        }, timeout: 30)
        guard reached else {
            throw HarnessFailure(description: "status never succeeded through the relay (broker or endpoint missing): \(last.summary)")
        }
        guard let object = CLITopology.jsonObject(in: last.output),
              let status = object["status"] as? [String: Any],
              let pid = (status["pid"] as? NSNumber)?.int32Value,
              let bundlePath = status["bundlePath"] as? String
        else { throw HarnessFailure(description: "status --json was not the expected JSON: \(last.output)") }
        XCTAssertEqual(pid, launchedProcessID(of: appURL), "the CLI answered from a different Batty process than the one XCUITest launched")
        XCTAssertEqual(
            URL(filePath: bundlePath).standardizedFileURL.path,
            appURL.standardizedFileURL.path,
            "the CLI answered from a different bundle than the one XCUITest launched"
        )
        guard let topology = waitForTopology(timeout: 20, { !$0.sessions.isEmpty }) else {
            throw HarnessFailure(description: "list --json never reported a Session after launch")
        }
        return (appURL, topology)
    }

    /// The pid of the one running instance of the bundle XCUITest launched.
    /// `nil` when none or more than one is running, which would make a pid
    /// comparison meaningless.
    static func launchedProcessID(of appURL: URL) -> Int32? {
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return running.count == 1 ? running[0].processIdentifier : nil
    }

    /// A scratch directory under the runner's temp directory. Named with the
    /// `batty-ui-test-` prefix so `BattyUITestHarness.sweepSentinels()`
    /// removes it. Not `/tmp`: the guest denies the runner writes there (#0416).
    static func makeScratchDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "batty-ui-test-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real, empty git repository with one untracked file, written without
    /// running `git` (the sandboxed runner may not be able to).
    @discardableResult
    static func makeGitRepository(in scratch: URL, named name: String = "repo") throws -> URL {
        let repo = scratch.appending(path: name)
        let git = repo.appending(path: ".git")
        let fm = FileManager.default
        for sub in ["objects", "refs/heads", "refs/tags"] {
            try fm.createDirectory(at: git.appending(path: sub), withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n".write(to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: repo.appending(path: "untracked-file.txt"), atomically: true, encoding: .utf8)
        return repo
    }

    /// Writes a shell script and returns the `pane split --command` string
    /// that runs it in a Pane (with that Pane's `BATTY_*` environment). It is
    /// run as `/bin/sh <path>` rather than executed directly: a file the
    /// sandboxed runner creates carries a quarantine attribute, and executing
    /// it fails with "bad interpreter: Operation not permitted" (VM run
    /// 20261006-032012-68568). The path has no spaces, so it needs no quoting.
    static func makeScript(in scratch: URL, named name: String, body: String) throws -> String {
        let url = scratch.appending(path: name)
        try "\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return "/bin/sh \(url.path)"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func readTrimmed(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads the accessibility tree the way the CLI-driven tests need it: each
/// Pane is identified by an id-keyed anchor, never by "the first terminal".
nonisolated enum BattyScreen {
    /// A terminal Pane's body is `pane-terminal.<id>`; a non-terminal Pane
    /// has no terminal body, so its id-keyed header close button stands in.
    static func anchorIdentifier(for pane: CLITopology.Pane) -> String {
        pane.kind == "terminal" ? "pane-terminal.\(pane.id.uuidString)" : "pane-close-button.\(pane.id.uuidString)"
    }

    @MainActor
    static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    static func elements(withPrefix prefix: String, in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    /// Distinct identifiers, because SwiftUI can surface one identifier on
    /// more than one accessibility element.
    @MainActor
    static func identifiers(withPrefix prefix: String, in app: XCUIApplication) -> Set<String> {
        Set(elements(withPrefix: prefix, in: app).map(\.identifier))
    }

    @MainActor
    static func terminalPane(_ id: UUID, in app: XCUIApplication) -> XCUIElement {
        element("pane-terminal.\(id.uuidString)", in: app)
    }

    @MainActor
    static func paneAnchor(_ pane: CLITopology.Pane, in app: XCUIApplication) -> XCUIElement {
        element(anchorIdentifier(for: pane), in: app)
    }

    static func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }

    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat { area(a.intersection(b)) }

    /// `nil` when the on-screen state agrees with `topology`, else a
    /// description of the first disagreement:
    /// - the Sidebar's Session rows are exactly the topology's Sessions;
    /// - each visible Pane of the selected Session has its anchor on screen
    ///   with a non-empty frame, and each hidden one has none;
    /// - no Pane anchor is on screen that the topology does not list at all.
    ///
    /// Non-selected Sessions stay mounted at zero opacity
    /// (`docs/view-hierarchy.md`), so their Panes may also be in the tree and
    /// are only checked against the "listed" rule.
    @MainActor
    static func mismatch(between topology: CLITopology, in app: XCUIApplication) -> String? {
        let rows = identifiers(withPrefix: "session-row.", in: app)
        let expectedRows = Set(topology.sessions.map { "session-row.\($0.name)" })
        if rows != expectedRows {
            return "Sidebar Session rows \(rows.sorted()) != topology Sessions \(expectedRows.sorted())"
        }
        guard let selected = topology.selectedSession else { return "topology has no selected Session" }
        for pane in selected.panes {
            let anchor = paneAnchor(pane, in: app)
            if pane.isHidden {
                if anchor.exists { return "hidden Pane \(pane.id) (\(pane.kind)) is still on screen" }
            } else if !anchor.exists {
                return "visible Pane \(pane.id) (\(pane.kind)) is not on screen"
            } else if anchor.frame.width < 1 || anchor.frame.height < 1 {
                return "visible Pane \(pane.id) (\(pane.kind)) has an empty frame \(anchor.frame)"
            }
        }
        let listed = Set(topology.allPaneIDs.map(\.uuidString))
        for prefix in ["pane-terminal.", "pane-close-button."] {
            for identifier in identifiers(withPrefix: prefix, in: app) {
                let id = String(identifier.dropFirst(prefix.count))
                if !listed.contains(id) { return "on-screen \(identifier) is not in list --json (orphaned Pane)" }
            }
        }
        return nil
    }

    /// Waits for the screen to agree with `topology` and fails with the
    /// disagreement otherwise.
    @MainActor
    static func expectMatches(_ topology: CLITopology, in app: XCUIApplication, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        var last: String?
        BattyUITestHarness.waitFor({
            last = mismatch(between: topology, in: app)
            return last == nil
        }, timeout: timeout)
        XCTAssertNil(last, "screen disagrees with list --json: \(last ?? "")", file: file, line: line)
    }
}
