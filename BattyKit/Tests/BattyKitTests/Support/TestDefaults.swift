// TestDefaults.swift

import Foundation

/// A `UserDefaults` instance backed by a unique, disposable suite — never
/// `.standard`, which every concurrent `./build.sh unit` run on the machine
/// shares through one `cfprefsd` (#0426). Isolation comes from the unique
/// suite name, not from creating a new `UserDefaults` instance: two
/// instances with the same suite name share the same backing store.
///
/// The suite name is an absolute path under a per-run temp directory
/// (`NSTemporaryDirectory()/batty-tests/<run-uuid>/tests.<function>.<UUID>`),
/// not a reverse-DNS string. Verified empirically, 20/20: a reverse-DNS
/// suite name (e.g. `"tests.foo.<UUID>"`) makes `cfprefsd` re-create an
/// empty plist under `~/Library/Preferences` within seconds, no matter how
/// teardown is ordered — the daemon's own write-behind queue reflushes a
/// domain client-side APIs already asked it to forget, and nothing run from
/// this process can close that race. An absolute path under the temp
/// directory doesn't have that problem: `cfprefsd` backs it with a plist at
/// that exact path rather than under `~/Library/Preferences`, two instances
/// created with the same path still share one backing store, and nothing
/// leaks into `.standard` — all verified directly (write via one instance,
/// read via a second; diff `~/Library/Preferences` before/after).
///
/// Call `tearDown()` when the test finishes to remove the suite's on-disk
/// state. The containing per-run directory is left for `NSTemporaryDirectory()`'s
/// own cleanup rather than raced against still-running sibling tests.
///
/// A `@MainActor` test class's `deinit` runs nonisolated by default (Swift
/// won't let it touch a `TestDefaults` property without an explicit
/// `@MainActor deinit`, since this type isn't `Sendable`) — declare
/// `@MainActor deinit { testDefaults.tearDown() }` on the owning test class
/// rather than a plain `deinit`.
final class TestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    /// One directory per test process, under the system temp directory —
    /// never `~/Library/Preferences`. Lazily created on first use and shared
    /// by every `TestDefaults` instance in this process.
    private static let runDirectory: URL = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("batty-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    init(function: String = #function) {
        let safeName = function.filter { $0.isLetter || $0.isNumber }
        suiteName = Self.runDirectory
            .appendingPathComponent("tests.\(safeName).\(UUID().uuidString)")
            .path
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults suite \(suiteName)")
        }
        self.defaults = defaults
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }
}
