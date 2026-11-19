// StaticServerPureTests.swift

import Foundation
import Testing
@testable import BattyKit

nonisolated struct HTTPRequestHeadTests {
    @Test func parsesGetWithHeaders() throws {
        let head = try HTTPRequestHead.parse(Data("GET /a?b HTTP/1.1\r\nHost: x\r\nUser-Agent: y\r\n\r\n".utf8)).get()
        #expect(head.method == "GET")
        #expect(head.target == "/a?b")
        #expect(head.version == "HTTP/1.1")
        #expect(head.header("host") == "x")
    }

    @Test func headerNamesAreCaseInsensitive() throws {
        let head = try HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHOST: x\r\n\r\n".utf8)).get()
        #expect(head.header("Host") == "x")
    }

    @Test func incompleteHeadIsIncomplete() {
        #expect(HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == .failure(.incomplete))
    }

    @Test func missingVersionIsMalformed() {
        #expect(HTTPRequestHead.parse(Data("GET /\r\n\r\n".utf8)) == .failure(.malformed))
        #expect(HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nnocolon\r\n\r\n".utf8)) == .failure(.malformed))
    }

    @Test func headOver16KiBIsTooLarge() {
        let big = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 17 * 1024)
        #expect(HTTPRequestHead.parse(Data(big.utf8)) == .failure(.tooLarge))
        #expect(HTTPRequestHead.parse(Data((big + "\r\n\r\n").utf8)) == .failure(.tooLarge))
    }
}

nonisolated struct StaticFilePathResolverTests {
    private func withResolver(_ body: (StaticFilePathResolver, StaticServerFixture) throws -> Void) throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let resolver = try #require(StaticFilePathResolver(root: fixture.root))
        try body(resolver, fixture)
    }

    private func isFile(_ resolution: StaticResolution, endingWith suffix: String) -> Bool {
        if case .file(let url) = resolution { return url.path.hasSuffix(suffix) }
        return false
    }

    @Test func rootServesIndexHTML() throws {
        try withResolver { resolver, _ in #expect(isFile(resolver.resolve(target: "/"), endingWith: "/site/index.html")) }
    }

    @Test func nestedFileResolves() throws {
        try withResolver { resolver, _ in #expect(isFile(resolver.resolve(target: "/sub/page.html"), endingWith: "/sub/page.html")) }
    }

    @Test func directoryWithoutSlashRedirects() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/sub") == .redirect(location: "/sub/"))
            #expect(resolver.resolve(target: "//sub") == .redirect(location: "/sub/"))
        }
    }

    @Test func directoryWithoutIndexLists() throws {
        try withResolver { resolver, _ in
            guard case .listing(_, let relative) = resolver.resolve(target: "/docs/") else {
                Issue.record("expected a listing")
                return
            }
            #expect(relative == "/docs/")
        }
    }

    @Test func dotDotSegmentIsForbidden() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/../outside/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/sub/../../outside/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/sub/../index.html") == .forbidden)
        }
    }

    @Test func percentEncodedDotDotIsForbidden() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/%2e%2e/outside/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/%2E%2E%2Foutside/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/..%2foutside/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/sub/%2e%2e%5c..") == .notFound)
        }
    }

    @Test func doubleEncodedDotDotIsOnlyAMissingFile() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/%252e%252e/outside/secret.txt") == .notFound)
        }
    }

    @Test func nulByteIsForbidden() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/index.html%00.txt") == .forbidden)
            #expect(resolver.resolve(target: "/bad%zzencoding") == .forbidden)
        }
    }

    @Test func symlinkOutsideRootIsForbidden() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/outside-link.txt") == .forbidden)
            #expect(resolver.resolve(target: "/outside-dir/secret.txt") == .forbidden)
            #expect(resolver.resolve(target: "/outside-dir/") == .forbidden)
        }
    }

    @Test func symlinkInsideRootResolves() throws {
        try withResolver { resolver, _ in #expect(isFile(resolver.resolve(target: "/inside-link.html"), endingWith: "/sub/page.html")) }
    }

    @Test func dotfilesAndDotDirectoriesAreNotFound() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "/.env") == .notFound)
            #expect(resolver.resolve(target: "/.git/config") == .notFound)
            #expect(resolver.resolve(target: "/.git/") == .notFound)
            #expect(resolver.resolve(target: "/%2eenv") == .notFound)
            #expect(resolver.resolve(target: "/.missing") == .notFound)
        }
    }

    @Test func queryAndFragmentAreIgnored() throws {
        try withResolver { resolver, _ in
            #expect(isFile(resolver.resolve(target: "/sub/page.html?x=../../etc"), endingWith: "/sub/page.html"))
            #expect(isFile(resolver.resolve(target: "/sub/page.html#frag"), endingWith: "/sub/page.html"))
        }
    }

    @Test func symlinkedRootStillServes() throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        let resolver = try #require(StaticFilePathResolver(root: fixture.symlinkedRoot))
        #expect(isFile(resolver.resolve(target: "/sub/page.html"), endingWith: "/sub/page.html"))
        #expect(resolver.resolve(target: "/outside-link.txt") == .forbidden)
    }

    @Test func fifoIsNotFound() throws {
        try withResolver { resolver, _ in #expect(resolver.resolve(target: "/pipe") == .notFound) }
    }

    @Test func reservedPrefixNeverMapsToAFile() throws {
        try withResolver { resolver, fixture throws in
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("__batty"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: fixture.root.appendingPathComponent("__batty/reload"))
            #expect(resolver.resolve(target: "/__batty/reload") == .reserved)
            #expect(resolver.resolve(target: "/%5f_batty/reload") == .reserved)
        }
    }

    @Test func nonOriginFormTargetIsForbidden() throws {
        try withResolver { resolver, _ in
            #expect(resolver.resolve(target: "http://evil/") == .forbidden)
            #expect(resolver.resolve(target: "*") == .forbidden)
        }
    }
}

nonisolated struct StaticFileMIMETypeTests {
    @Test func htmlIsTextHTMLUTF8() { #expect(StaticFileMIMEType.mimeType(forPathExtension: "html") == "text/html; charset=utf-8") }
    @Test func javascriptAndModules() {
        #expect(StaticFileMIMEType.mimeType(forPathExtension: "js") == "text/javascript; charset=utf-8")
        #expect(StaticFileMIMEType.mimeType(forPathExtension: "mjs") == "text/javascript; charset=utf-8")
    }
    @Test func wasmIsApplicationWasm() { #expect(StaticFileMIMEType.mimeType(forPathExtension: "wasm") == "application/wasm") }
    @Test func svgAndJSON() {
        #expect(StaticFileMIMEType.mimeType(forPathExtension: "svg") == "image/svg+xml; charset=utf-8")
        #expect(StaticFileMIMEType.mimeType(forPathExtension: "json") == "application/json; charset=utf-8")
        #expect(StaticFileMIMEType.mimeType(forPathExtension: "png") == "image/png")
    }
    @Test func extensionIsCaseInsensitive() { #expect(StaticFileMIMEType.mimeType(forPathExtension: "HTML") == "text/html; charset=utf-8") }
    @Test func unknownIsOctetStream() { #expect(StaticFileMIMEType.mimeType(forPathExtension: "xyz") == "application/octet-stream") }
}

nonisolated struct ByteRangeTests {
    @Test func startAndEnd() { #expect(ByteRange.parse(header: "bytes=2-5", size: 10) == .partial(2...5)) }
    @Test func openEnded() { #expect(ByteRange.parse(header: "bytes=4-", size: 10) == .partial(4...9)) }
    @Test func suffix() {
        #expect(ByteRange.parse(header: "bytes=-3", size: 10) == .partial(7...9))
        #expect(ByteRange.parse(header: "bytes=-30", size: 10) == .partial(0...9))
    }
    @Test func beyondSizeIsUnsatisfiable() {
        #expect(ByteRange.parse(header: "bytes=10-", size: 10) == .unsatisfiable)
        #expect(ByteRange.parse(header: "bytes=0-", size: 0) == .unsatisfiable)
        #expect(ByteRange.parse(header: "bytes=5-100", size: 10) == .partial(5...9))
    }
    @Test func multipleRangesServeFull() {
        #expect(ByteRange.parse(header: "bytes=0-1,3-4", size: 10) == .full)
        #expect(ByteRange.parse(header: nil, size: 10) == .full)
        #expect(ByteRange.parse(header: "bytes=5-2", size: 10) == .full)
    }
}

nonisolated struct ReloadScriptInjectorTests {
    private func injected(_ html: String) -> String {
        String(decoding: ReloadScriptInjector.inject(into: Data(html.utf8)), as: UTF8.self)
    }

    @Test func insertsBeforeClosingBody() {
        #expect(injected("<body>x</body></html>") == "<body>x\(ReloadScriptInjector.script)</body></html>")
    }

    @Test func matchesBodyCaseInsensitively() {
        #expect(injected("<BODY>x</BODY>") == "<BODY>x\(ReloadScriptInjector.script)</BODY>")
    }

    @Test func usesTheLastBodyTag() {
        #expect(injected("<p>\"</body>\"</p></body>") == "<p>\"</body>\"</p>\(ReloadScriptInjector.script)</body>")
    }

    @Test func appendsWhenThereIsNoBody() {
        #expect(injected("<p>x</p>") == "<p>x</p>\(ReloadScriptInjector.script)")
        #expect(injected("") == ReloadScriptInjector.script)
    }
}

nonisolated struct StaticHTTPResponderTests {
    private let port: UInt16 = 4000

    private func respond(_ raw: String, fixture: StaticServerFixture, inject: Bool = true) throws -> StaticResponse {
        let head = try HTTPRequestHead.parse(Data(raw.utf8)).get()
        let resolver = try #require(StaticFilePathResolver(root: fixture.root))
        return StaticHTTPResponder.respond(to: head, resolver: resolver, options: StaticResponderOptions(port: port, injectsReloadScript: inject))
    }

    private func get(_ target: String, host: String? = nil, extra: String = "", method: String = "GET") -> String {
        "\(method) \(target) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n\(extra)\r\n"
    }

    private func withFixture(_ body: (StaticServerFixture) throws -> Void) throws {
        let fixture = try StaticServerFixture()
        defer { fixture.remove() }
        try body(fixture)
    }

    @Test func foreignHostHeaderIsForbidden() throws {
        try withFixture { fixture throws in
            #expect(try respond(get("/", host: "evil.example:\(port)"), fixture: fixture).status == 403)
            #expect(try respond(get("/", host: "127.0.0.1"), fixture: fixture).status == 403)
            #expect(try respond(get("/", host: "127.0.0.1:1"), fixture: fixture).status == 403)
            #expect(try respond("GET / HTTP/1.1\r\n\r\n", fixture: fixture).status == 403)
        }
    }

    @Test func localhostAnd127AndIPv6HostsAreAccepted() throws {
        try withFixture { fixture throws in
            for host in ["127.0.0.1:\(port)", "localhost:\(port)", "LOCALHOST:\(port)", "[::1]:\(port)"] {
                #expect(try respond(get("/", host: host), fixture: fixture).status == 200)
            }
        }
    }

    @Test func postIsMethodNotAllowedWithAllow() throws {
        try withFixture { fixture throws in
            let response = try respond(get("/", method: "POST"), fixture: fixture)
            #expect(response.status == 405)
            #expect(response.header("Allow") == "GET, HEAD")
        }
    }

    @Test func headHasHeadersAndNoBody() throws {
        try withFixture { fixture throws in
            let response = try respond(get("/docs/a.txt", method: "HEAD"), fixture: fixture)
            #expect(response.status == 200)
            #expect(response.body.isEmpty)
            #expect(response.header("Content-Length") == "3")
        }
    }

    @Test func htmlForBrowsersGetsTheScript() throws {
        try withFixture { fixture throws in
            let response = try respond(get("/"), fixture: fixture)
            #expect(String(decoding: response.body, as: UTF8.self).contains(ReloadScriptInjector.script))
        }
    }

    @Test func battyPreviewUserAgentGetsExactBytes() throws {
        try withFixture { fixture throws in
            let response = try respond(get("/", extra: "User-Agent: Mozilla/5.0 BattyPreview/1\r\n"), fixture: fixture)
            let original = try Data(contentsOf: fixture.root.appendingPathComponent("index.html"))
            #expect(response.body == original)
        }
    }

    @Test func noInjectServesExactBytes() throws {
        try withFixture { fixture throws in
            let response = try respond(get("/"), fixture: fixture, inject: false)
            let original = try Data(contentsOf: fixture.root.appendingPathComponent("index.html"))
            #expect(response.body == original)
        }
    }

    @Test func nonHTMLIsNeverInjected() throws {
        try withFixture { fixture throws in
            #expect(try respond(get("/docs/a.txt"), fixture: fixture).body == Data("doc".utf8))
        }
    }

    @Test func rangeOnInjectedHTMLServesFull() throws {
        try withFixture { fixture throws in
            let injected = try respond(get("/", extra: "Range: bytes=0-3\r\n"), fixture: fixture)
            #expect(injected.status == 200)
            let plain = try respond(get("/", extra: "Range: bytes=0-3\r\n"), fixture: fixture, inject: false)
            #expect(plain.status == 206)
            #expect(plain.body == Data("<htm".utf8))
            #expect(plain.header("Content-Range") == "bytes 0-3/40")
            #expect(try respond(get("/docs/a.txt", extra: "Range: bytes=9-\r\n"), fixture: fixture).status == 416)
        }
    }

    @Test func listingEscapesNames() throws {
        try withFixture { fixture throws in
            try Data().write(to: fixture.root.appendingPathComponent("docs/<b>&\".txt"))
            let body = String(decoding: try respond(get("/docs/"), fixture: fixture).body, as: UTF8.self)
            #expect(body.contains("&lt;b&gt;&amp;&quot;.txt"))
            #expect(!body.contains("<b>&"))
            #expect(body.contains("a.txt"))
        }
    }

    @Test func responsesAreNoStore() throws {
        try withFixture { fixture throws in
            for target in ["/", "/.env", "/sub", "/../x"] {
                let response = try respond(get(target), fixture: fixture)
                #expect(response.header("Cache-Control") == "no-store")
                #expect(response.header("X-Content-Type-Options") == "nosniff")
                #expect(response.header("Access-Control-Allow-Origin") == nil)
            }
        }
    }

    @Test func traversalStatusesOverTheResponder() throws {
        try withFixture { fixture throws in
            #expect(try respond(get("/../outside/secret.txt"), fixture: fixture).status == 403)
            #expect(try respond(get("/.env"), fixture: fixture).status == 404)
            #expect(try respond(get("/__batty/x"), fixture: fixture).status == 404)
            #expect(try respond(get("/sub"), fixture: fixture).header("Location") == "/sub/")
        }
    }
}

nonisolated struct StaticChangeFilterTests {
    @Test func ignoresDotGitChanges() {
        #expect(!StaticChangeFilter.isRelevant(path: "/r/site/.git/index", root: "/r/site"))
        #expect(!StaticChangeFilter.isRelevant(path: "/r/site/a/.page.swp", root: "/r/site"))
    }

    @Test func keepsOrdinaryFiles() {
        #expect(StaticChangeFilter.isRelevant(path: "/r/site/index.html", root: "/r/site"))
        #expect(StaticChangeFilter.isRelevant(path: "/r/site", root: "/r/site"))
    }

    @Test func ignoresPathsOutsideTheRoot() {
        #expect(!StaticChangeFilter.isRelevant(path: "/r/site2/index.html", root: "/r/site"))
        #expect(!StaticChangeFilter.isRelevant(path: "/r/other", root: "/r/site"))
    }
}
