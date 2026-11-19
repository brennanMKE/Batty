// ServerStatsParserTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ServerStatsParserTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesExpvarMemstatsAllowListAndCmdline() throws {
        let url = try #require(Bundle.module.url(forResource: "expvar-sample", withExtension: "json", subdirectory: "Fixtures"))
        let snapshot = try #require(ServerStatsParser.parse(try Data(contentsOf: url), isExpvar: true))
        let memstats = Set(snapshot.numbers.keys.filter { $0.hasPrefix("memstats.") })
        #expect(memstats == Set(ServerStatsParser.memstatsAllowList.map { "memstats.\($0)" }))
        #expect(snapshot.numbers["memstats.NumGC"] == 12)
        #expect(snapshot.numbers["requests"] == 480)
        #expect(snapshot.texts["cmdline"] == "/tmp/go-build123/b001/exe/site -addr :8083")
        #expect(snapshot.texts["build.version"] == "1.2.3")
    }

    @Test func flattensNestedAppVarsToDottedKeys() throws {
        let snapshot = try #require(ServerStatsParser.parse(json(#"{"app":{"cache":{"hits":3}}}"#), isExpvar: false))
        #expect(snapshot.numbers == ["app.cache.hits": 3])
    }

    @Test func treatsBoolsAsTextNotNumbers() throws {
        let snapshot = try #require(ServerStatsParser.parse(json(#"{"ready":true,"n":1}"#), isExpvar: false))
        #expect(snapshot.numbers == ["n": 1])
        #expect(snapshot.texts == ["ready": "true"])
    }

    @Test func skipsArraysOtherThanCmdline() throws {
        let snapshot = try #require(ServerStatsParser.parse(json(#"{"list":[1,2],"cmdline":["a","b"]}"#), isExpvar: false))
        #expect(snapshot.numbers.isEmpty)
        #expect(snapshot.texts == ["cmdline": "a b"])
    }

    @Test func returnsNilForNonJSON() {
        #expect(ServerStatsParser.parse(json("<html>404</html>"), isExpvar: true) == nil)
    }

    @Test func returnsNilForANonObjectRoot() {
        #expect(ServerStatsParser.parse(json("[1,2,3]"), isExpvar: false) == nil)
    }

    @Test func capsAt24NumericSeries() throws {
        let body = "{" + (0..<40).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
        let snapshot = try #require(ServerStatsParser.parse(json(body), isExpvar: false))
        #expect(snapshot.numbers.count == ServerStatsParser.maxNumericSeries)
    }
}

struct ServerStatsHistoryTests {
    @Test func keepsTheLast60Samples() {
        var history = ServerStatsHistory()
        for value in 0..<100 { history.append(ServerStatsSnapshot(numbers: ["n": Double(value)])) }
        #expect(history.series["n"]?.count == 60)
        #expect(history.series["n"]?.first == 40)
        #expect(history.series["n"]?.last == 99)
    }

    @Test func changedKeysExcludeConstants() {
        var history = ServerStatsHistory()
        history.append(ServerStatsSnapshot(numbers: ["moving": 1, "fixed": 7]))
        history.append(ServerStatsSnapshot(numbers: ["moving": 2, "fixed": 7]))
        #expect(history.changedKeys == ["moving"])
    }
}
