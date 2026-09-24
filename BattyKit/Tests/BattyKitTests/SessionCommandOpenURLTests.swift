// SessionCommandOpenURLTests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers `openURL`'s `resolveAppBundle` seam (#0361 round 3) and its
/// `runProcess` seam (#0414). `runProcess` stands in for the real
/// `/usr/bin/open -a <bundlePath> <url>` spawn, so these tests pin the exact
/// argv and the exit-code mapping without ever spawning a real process or
/// launching/activating an app bundle.
struct SessionCommandOpenURLTests {

    private struct SpawnFailure: Error {}

    private let fakeURL = URL(string: "batty://session?path=/tmp")!

    /// Contains a space so a successful test also proves the bundle path is
    /// passed to `runProcess` unencoded (#0361's `-a <path>` fix, not
    /// percent-escaped).
    private let fakeBundleURL = URL(fileURLWithPath: "/Applications/Batty Beta.app", isDirectory: true)

    @Test func bundleResolutionFailureExitsWithAppBundleUnresolvedWithoutSpawningOpen() {
        let failure = AppBundleLocator.Failure.expectedBundleMissing(expectedPath: "/Applications/Batty.app", otherClaimants: [])
        var runProcessCalls = 0

        #expect(throws: ExitCode(XPCExitCode.appBundleUnresolved)) {
            try openURL(fakeURL, resolveAppBundle: { .failure(failure) }, runProcess: { _, _ in
                runProcessCalls += 1
                return 0
            })
        }
        #expect(runProcessCalls == 0)
    }

    @Test func successfulResolveInvokesOpenWithPathTargetedArgvExactlyOnce() throws {
        var runProcessCalls = 0
        var capturedExecutableURL: URL?
        var capturedArguments: [String]?

        try openURL(
            fakeURL,
            resolveAppBundle: { .success(fakeBundleURL) },
            runProcess: { executableURL, arguments in
                runProcessCalls += 1
                capturedExecutableURL = executableURL
                capturedArguments = arguments
                return 0
            }
        )

        #expect(runProcessCalls == 1)
        #expect(capturedExecutableURL == URL(filePath: "/usr/bin/open"))
        #expect(capturedArguments == ["-a", fakeBundleURL.path(percentEncoded: false), fakeURL.absoluteString])
        #expect(capturedArguments?.contains("-b") == false)
    }

    @Test func zeroExitStatusReturnsWithoutThrowing() throws {
        try openURL(fakeURL, resolveAppBundle: { .success(fakeBundleURL) }, runProcess: { _, _ in 0 })
    }

    @Test func nonZeroExitStatusThrowsExitCodeFailure() {
        #expect(throws: ExitCode.failure) {
            try openURL(fakeURL, resolveAppBundle: { .success(fakeBundleURL) }, runProcess: { _, _ in 1 })
        }
    }

    @Test func spawnFailureThrowsExitCodeFailure() {
        #expect(throws: ExitCode.failure) {
            try openURL(fakeURL, resolveAppBundle: { .success(fakeBundleURL) }, runProcess: { _, _ in throw SpawnFailure() })
        }
    }
}
