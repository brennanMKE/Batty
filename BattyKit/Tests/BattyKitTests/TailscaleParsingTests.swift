// TailscaleParsingTests.swift

import Foundation
import Testing
@testable import BattyKit

private func status(_ json: String) -> TailnetStatus {
    TailnetStatus.parse(Data(json.utf8))
}

private func serve(_ json: String) throws -> TailscaleServeConfig {
    try #require(TailscaleServeConfig.parse(Data(json.utf8)))
}

struct TailscaleStatusParsingTests {
    @Test func runningStatusYieldsTheDNSNameWithoutTrailingDot() {
        #expect(status(TailscaleFixtures.running) == .running(dnsName: "host.tailnet.ts.net", httpsEnabled: true))
    }

    @Test func runningWithoutCertDomainsHasHTTPSOff() {
        #expect(status(TailscaleFixtures.runningNoHTTPS) == .running(dnsName: "host.tailnet.ts.net", httpsEnabled: false))
    }

    @Test func stoppedIsNotRunning() {
        #expect(status(TailscaleFixtures.stopped) == .notRunning(backendState: "Stopped"))
    }

    @Test func loggedOutIsNotRunningWithNeedsLogin() {
        #expect(status(TailscaleFixtures.loggedOut) == .notRunning(backendState: "NeedsLogin"))
    }

    @Test func missingSelfIsNotRunning() {
        #expect(status(TailscaleFixtures.missingSelf) == .notRunning(backendState: "NoDNSName"))
    }

    @Test func malformedJSONIsUnavailable() {
        #expect(status(TailscaleFixtures.malformed) == .unavailable)
    }

    @Test func tailnetURLOmitsPort443() {
        #expect(TailnetURL.make(dnsName: "host.tailnet.ts.net", port: 443).absoluteString == "https://host.tailnet.ts.net/")
    }

    @Test func tailnetURLIncludesOtherPorts() {
        #expect(TailnetURL.make(dnsName: "host.tailnet.ts.net", port: 3000).absoluteString == "https://host.tailnet.ts.net:3000/")
    }
}

struct TailscaleServeConfigParsingTests {
    let dns = TailscaleFixtures.dnsName

    @Test func emptyConfigHasNoMapping() throws {
        let config = try serve(TailscaleFixtures.emptyServe)
        #expect(!config.hasAnyMapping(port: 3000))
        #expect(!config.isOurs(port: 3000, dnsName: dns))
    }

    @Test func oursIsRecognized() throws {
        let config = try serve(TailscaleFixtures.oursOn3000)
        #expect(config.isOurs(port: 3000, dnsName: dns))
        #expect(!config.hasAnyMapping(port: 3001))
    }

    @Test func foreignProxyIsNotOurs() throws {
        let config = try serve(TailscaleFixtures.foreignOn3000)
        #expect(config.hasAnyMapping(port: 3000))
        #expect(!config.isOurs(port: 3000, dnsName: dns))
    }

    @Test func extraHandlersAreNotOurs() throws {
        let config = try serve(TailscaleFixtures.twoHandlersOn3000)
        #expect(config.hasAnyMapping(port: 3000))
        #expect(!config.isOurs(port: 3000, dnsName: dns))
    }

    @Test func tcpForwardIsAMappingButNotOurs() throws {
        let config = try serve(TailscaleFixtures.tcpForwardOn3000)
        #expect(config.hasAnyMapping(port: 3000))
        #expect(!config.isOurs(port: 3000, dnsName: dns))
    }

    @Test func unknownKeysAreIgnored() throws {
        let config = try serve(#"{"Services":{"svc:x":{}},"Foreground":{},"TCP":{"3000":{"HTTPS":true}},"Web":{"host.tailnet.ts.net:3000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000/"}}}}}"#)
        #expect(config.isOurs(port: 3000, dnsName: dns))
    }
}

struct TailscaleExecutableLocatorTests {
    @Test func findsTheCLIOnPATH() {
        let found = TailscaleExecutableLocator.locate(environmentPATH: "/usr/bin:/opt/tools/bin") { $0 == "/opt/tools/bin/tailscale" || $0 == "/usr/local/bin/tailscale" }
        #expect(found?.path == "/opt/tools/bin/tailscale")
    }

    @Test func checksUsrLocalAndHomebrewWhenPATHLacksThem() {
        #expect(TailscaleExecutableLocator.locate(environmentPATH: "/usr/bin") { $0 == "/usr/local/bin/tailscale" }?.path == "/usr/local/bin/tailscale")
        #expect(TailscaleExecutableLocator.locate(environmentPATH: "/usr/bin") { $0 == "/opt/homebrew/bin/tailscale" }?.path == "/opt/homebrew/bin/tailscale")
    }

    @Test func fallsBackToTheAppBundleCLI() {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        #expect(TailscaleExecutableLocator.locate(environmentPATH: nil) { $0 == app }?.path == app)
    }

    @Test func returnsNilWhenNoneExists() {
        #expect(TailscaleExecutableLocator.locate(environmentPATH: "/usr/bin") { _ in false } == nil)
    }
}

nonisolated struct ProcessTailscaleCommandRunnerTests {
    @Test func capturesStdoutStderrAndExitCode() async {
        let result = await ProcessTailscaleCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: .seconds(30))
        #expect(result == TailscaleCommandResult(exitCode: 3, stdout: "out\n", stderr: "err\n", timedOut: false))
    }
}
