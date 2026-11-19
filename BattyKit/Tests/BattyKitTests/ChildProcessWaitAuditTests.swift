// ChildProcessWaitAuditTests.swift

import Foundation
import Testing

/// Lexical rules for `docs/async-test-seams.md` §8: no blocking wait on a
/// child process from main-actor test code, and no fixture child that lives
/// on a wall-clock `sleep`. Heuristic by design; see §8 for its limits.
nonisolated enum ChildProcessWaitAudit {
    static let allowlist: Set<String> = [
        "ChildProcessFixture.swift",
        "SignalAudit.swift",
        "AtlasOwnershipExperimentTests.swift",
        "ChildProcessWaitAuditTests.swift",
    ]

    private static let blockingWait = try! NSRegularExpression(
        pattern: #"\.waitUntilExit\(\)|(?<![A-Za-z_])waitpid\(|\.reapNow\(\)|(?<![A-Za-z_])killAndReap(All)?\("#)
    private static let timedSleep = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z_.])(/bin/)?sleep["']?[\s,]+["']?([0-9]+(\.[0-9]+)?)"#)
    private static let argumentsValue = try! NSRegularExpression(pattern: #"\[\s*"([0-9.]+)""#)
    private static let topLevelDeclaration = try! NSRegularExpression(
        pattern: #"^([A-Za-z@()_]+\s+)*(struct|class|enum|extension|actor)\s"#)

    /// Blocking waits outside lexically `nonisolated` code.
    static func offenders(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || !matches(blockingWait, line) { continue }
            if line.contains("waitpid("), line.contains("WNOHANG"), !matches(blockingWait, line.replacingOccurrences(of: "waitpid(", with: "")) {
                continue
            }
            if isNonisolated(lineAt: index, in: lines) { continue }
            result.append("\(file):\(index + 1): \(code)")
        }
        return result
    }

    /// Children started on a `sleep` of one second or more.
    static func timedChildren(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            var offending = captures(timedSleep, line, group: 2).contains { (Double($0) ?? 0) >= 1 }
            if !offending, line.contains("\"/bin/sleep\"") {
                let following = lines[(index + 1)..<min(index + 4, lines.count)]
                offending = following.contains { next in
                    captures(argumentsValue, next, group: 1).contains { (Double($0) ?? 0) >= 1 }
                }
            }
            if offending { result.append("\(file):\(index + 1): \(code)") }
        }
        return result
    }

    private static func isNonisolated(lineAt index: Int, in lines: [String]) -> Bool {
        let indent = indentation(of: lines[index])
        for j in stride(from: index - 1, through: 0, by: -1) where indentation(of: lines[j]) < indent {
            let line = lines[j]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("func ") { continue }
            if line.contains("nonisolated") || (j > 0 && lines[j - 1].contains("nonisolated")) { return true }
            break
        }
        for j in stride(from: index - 1, through: 0, by: -1) {
            let line = lines[j]
            guard indentation(of: line) == 0, matches(topLevelDeclaration, line) else { continue }
            if line.contains("nonisolated") { return true }
            var k = j - 1
            while k >= 0, lines[k].hasPrefix("@") {
                if lines[k].contains("nonisolated") { return true }
                k -= 1
            }
            return false
        }
        return false
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func captures(_ regex: NSRegularExpression, _ text: String, group: Int) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    static func scanTestSources(_ rule: (String, String) -> [String], filePath: String) throws -> [String] {
        let root = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && !allowlist.contains(url.lastPathComponent) {
            offenders += rule(try String(contentsOf: url, encoding: .utf8), url.lastPathComponent)
        }
        return offenders.sorted()
    }
}

nonisolated struct ChildProcessWaitAuditTests {
    @Test func noMainActorCodeBlocksOnAChildProcess() throws {
        let offenders = try ChildProcessWaitAudit.scanTestSources(ChildProcessWaitAudit.offenders, filePath: #filePath)
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    @Test func noFixtureChildLivesOnAWallClockTimer() throws {
        let offenders = try ChildProcessWaitAudit.scanTestSources(ChildProcessWaitAudit.timedChildren, filePath: #filePath)
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    @Test func flagsAWaitInAMainActorTest() {
        let source = """
        @MainActor
        struct Suite {
            @Test func waits() throws {
                try process.run()
                process.waitUntilExit()
                ChildProcessFixture.killAndReap(process)
                child.reapNow()
            }
        }
        """
        #expect(ChildProcessWaitAudit.offenders(in: source, file: "S.swift").count == 3)
    }

    @Test func acceptsAWaitInANonisolatedFunctionOrType() {
        let function = """
        @MainActor
        struct Suite {
            nonisolated static func run() {
                process.waitUntilExit()
            }
            @Test
            nonisolated func other() {
                if true {
                    fixture.killAndReapAll()
                }
            }
        }
        """
        let type = """
        @Suite(.serialized)
        nonisolated struct Suite {
            @Test func waits() {
                process.waitUntilExit()
            }
        }
        """
        #expect(ChildProcessWaitAudit.offenders(in: function, file: "F.swift").isEmpty)
        #expect(ChildProcessWaitAudit.offenders(in: type, file: "T.swift").isEmpty)
    }

    @Test func ignoresCommentsAndNonBlockingWaitpid() {
        let source = """
        struct Suite {
            func check() async {
                // process.waitUntilExit()
                /// `killAndReap(_:)` is the synchronous form
                _ = waitpid(pid, &status, WNOHANG)
                await ChildProcessFixture.killAndAwaitExit(process)
                await fixture.killAndAwaitAll()
            }
        }
        """
        #expect(ChildProcessWaitAudit.offenders(in: source, file: "C.swift").isEmpty)
    }

    @Test func flagsSleepOfOneSecondOrMore() {
        let source = """
        spawn("/bin/sh -c 'echo ready; exec /bin/sleep 30'")
        TestChildSpawner.spawn("/bin/sleep", arguments: ["/bin/sleep", "30"], ownGroup: false)
        TestChildSpawner.spawn("/bin/sleep", arguments: ["sleep", "2"], ownGroup: true)
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["1"]
        """
        #expect(ChildProcessWaitAudit.timedChildren(in: source, file: "S.swift").count == 4)
    }

    @Test func acceptsSubSecondSleepAndTaskSleep() {
        let source = """
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try await Task.sleep(for: .seconds(5))
        await clock.sleep(for: .seconds(30))
        usleep(100)
        // sleep 30 in a comment
        """
        #expect(ChildProcessWaitAudit.timedChildren(in: source, file: "S.swift").isEmpty)
    }
}
