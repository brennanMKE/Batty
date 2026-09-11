// TabRuntimeCLIPathSeamTests.swift

import Foundation
import Testing
@testable import BattyKit

struct TabRuntimeCLIPathSeamTests {

    @Test func appendsCLIDirectoryAfterInheritedPath() {
        // Appended, not prepended (review round 1, N1): prepending would put
        // a binary named `batty` (both variants embed one at
        // `Contents/Resources/bin/batty`) ahead of an installed
        // `/usr/local/bin/batty`/`batty-beta` symlink, undoing #0277's
        // decision that exactly one symlink serves exactly one variant.
        let result = TabRuntimeCLIPathSeam.injectedPath(
            basePath: "/usr/local/bin:/usr/bin:/bin",
            bundlePath: "/Applications/Batty.app"
        )
        #expect(result == "/usr/local/bin:/usr/bin:/bin:/Applications/Batty.app/Contents/Resources/bin")
    }

    @Test func stripsTheAppsOwnMacOSDirectoryFromTheInheritedPath() {
        // This is exactly the collision from #0364: this filter is a
        // defensive strip, not a reaction to libghostty having *already*
        // appended `Contents/MacOS` to this base — `basePath` here is the
        // app process's own `PATH`, evaluated before libghostty computes the
        // spawned shell's environment at all (see this type's doc comment).
        // It guards against `Contents/MacOS` reaching the base PATH by any
        // other route (e.g. the app's own launch environment already having
        // it) so the collision can't resurface even then.
        let result = TabRuntimeCLIPathSeam.injectedPath(
            basePath: "/usr/local/bin:/usr/bin:/bin:/Applications/Batty.app/Contents/MacOS",
            bundlePath: "/Applications/Batty.app"
        )
        #expect(!result.contains("/Applications/Batty.app/Contents/MacOS"))
        #expect(result == "/usr/local/bin:/usr/bin:/bin:/Applications/Batty.app/Contents/Resources/bin")
    }

    @Test func fallsBackToStandardPathWhenBaseIsNil() {
        let result = TabRuntimeCLIPathSeam.injectedPath(basePath: nil, bundlePath: "/Applications/Batty.app")
        #expect(result == "/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Batty.app/Contents/Resources/bin")
    }

    @Test func fallsBackToStandardPathWhenBaseIsEmpty() {
        // N4: an empty (not nil) `PATH` must fall back the same way `nil`
        // does, rather than producing a single-entry PATH with only the CLI
        // directory on it.
        let result = TabRuntimeCLIPathSeam.injectedPath(basePath: "", bundlePath: "/Applications/Batty.app")
        #expect(result == "/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Batty.app/Contents/Resources/bin")
    }

    @Test func doesNotDuplicateTheCLIDirectoryIfAlreadyPresent() {
        let result = TabRuntimeCLIPathSeam.injectedPath(
            basePath: "/usr/bin:/Applications/Batty.app/Contents/Resources/bin",
            bundlePath: "/Applications/Batty.app"
        )
        #expect(result == "/usr/bin:/Applications/Batty.app/Contents/Resources/bin")
    }

    @Test func ignoresEmptyPathSegments() {
        let result = TabRuntimeCLIPathSeam.injectedPath(
            basePath: "/usr/bin::/bin:",
            bundlePath: "/Applications/Batty.app"
        )
        #expect(result == "/usr/bin:/bin:/Applications/Batty.app/Contents/Resources/bin")
    }
}
