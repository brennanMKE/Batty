// AppBundleResolutionTests.swift

import Testing
@testable import BattyKit

/// Covers the #0361 fix for ambiguous bundle-id resolution: deriving the
/// exact app bundle a CLI invocation should target from the CLI's own
/// (symlink-resolved) on-disk location, falling back to the well-known
/// per-variant `/Applications` path only when that's not possible. No
/// `FileManager`/symlink resolution here — that's `AppBundleLocator`'s job;
/// this type is a pure function of already-resolved strings.
struct AppBundleResolutionTests {

    @Test func derivesPathFromTheEmbeddedCLISuffix() {
        let resolution = AppBundleResolution.resolve(
            resolvedOwnExecutablePath: "/Applications/Batty.app/Contents/Resources/bin/batty",
            variant: .prod
        )
        #expect(resolution == .derivedFromOwnLocation(bundlePath: "/Applications/Batty.app"))
    }

    @Test func derivesPathFromAnArbitraryEnclosingDirectory() {
        // The whole point: this works identically for a DerivedData debug
        // build, a Release build, or the installed app — whichever bundle
        // this exact CLI copy actually lives inside.
        let resolution = AppBundleResolution.resolve(
            resolvedOwnExecutablePath: "/Users/dev/Library/Developer/Xcode/DerivedData/Batty-abc123/Build/Products/Debug/Batty.app/Contents/Resources/bin/batty",
            variant: .prod
        )
        #expect(resolution == .derivedFromOwnLocation(bundlePath: "/Users/dev/Library/Developer/Xcode/DerivedData/Batty-abc123/Build/Products/Debug/Batty.app"))
    }

    @Test func fallsBackWhenNotEmbedded() {
        // A standalone copy sitting directly on PATH (#0361's reporting
        // machine had exactly this after a stale, non-symlink install).
        let resolution = AppBundleResolution.resolve(
            resolvedOwnExecutablePath: "/usr/local/bin/batty",
            variant: .prod
        )
        #expect(resolution == .wellKnownApplicationsFallback(bundlePath: "/Applications/Batty.app"))
    }

    @Test func fallbackUsesTheBetaPathForTheBetaVariant() {
        let resolution = AppBundleResolution.resolve(
            resolvedOwnExecutablePath: "/usr/local/bin/batty-beta",
            variant: .beta
        )
        #expect(resolution == .wellKnownApplicationsFallback(bundlePath: "/Applications/Batty Beta.app"))
    }

    @Test func aBareSuffixWithNoEnclosingBundleFallsBackRatherThanProducingAnEmptyPath() {
        // Degenerate input (no realistic invocation produces this), but the
        // guard against an empty derived bundle path is load-bearing enough
        // to pin down explicitly.
        let resolution = AppBundleResolution.resolve(
            resolvedOwnExecutablePath: "/Contents/Resources/bin/batty",
            variant: .prod
        )
        #expect(resolution == .wellKnownApplicationsFallback(bundlePath: "/Applications/Batty.app"))
    }

    @Test func bundlePathAccessorReturnsTheUnderlyingPathForBothCases() {
        #expect(AppBundleResolution.derivedFromOwnLocation(bundlePath: "/a/b.app").bundlePath == "/a/b.app")
        #expect(AppBundleResolution.wellKnownApplicationsFallback(bundlePath: "/c/d.app").bundlePath == "/c/d.app")
    }
}
