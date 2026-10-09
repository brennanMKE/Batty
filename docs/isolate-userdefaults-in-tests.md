# Task: Isolate UserDefaults in Unit Tests

## Goal

Make unit tests that touch `UserDefaults` safe to run in parallel and independent of each other and of the developer's real app preferences. Tests must never read or write `UserDefaults.standard`.

## Approach

1. Inject `UserDefaults` into every type that currently uses `UserDefaults.standard`.
2. Add a test helper that creates a `UserDefaults` instance with a unique suite name per test and deletes its persistent domain afterward.
3. Update existing tests to use the helper.

Isolation comes from a unique suite name, not from creating a new instance. Two instances with the same suite name share the same backing store, so a fixed name like `"TestDefaults"` is not acceptable.

## Step 1: Find all usages

Search the production code (not tests) for:

- `UserDefaults.standard`
- `UserDefaults()` (the no-argument initializer is backed by the standard domains)
- `@AppStorage` (SwiftUI; see "Out of scope" below)

List each file and type before changing anything.

## Step 2: Refactor for injection

For each type that uses `UserDefaults.standard`, add an initializer parameter that defaults to `.standard` so call sites in the app do not change.

```swift
final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var theme: Theme {
        get { Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.theme) }
    }
}
```

Rules:

- Replace every internal reference to `UserDefaults.standard` in the type with the stored `defaults` property.
- If a type calls `register(defaults:)`, call it on the injected instance.
- Static or global helpers that use `.standard` should gain a `defaults:` parameter, or be converted to instance methods on an injected type.
- Do not change key names or stored value formats.

## Step 3: Add the test helper

Create `Tests/<TestTarget>/Support/TestDefaults.swift` (match the project's existing test target layout):

```swift
import Foundation

/// A UserDefaults instance backed by a unique, disposable suite.
/// Call `tearDown()` when the test finishes to delete the plist from disk.
final class TestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(function: String = #function) {
        let safeName = function.filter { $0.isLetter || $0.isNumber }
        suiteName = "tests.\(safeName).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults suite \(suiteName)")
        }
        self.defaults = defaults
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
```

Never use the app's bundle identifier or `NSGlobalDomain` as a suite name; `UserDefaults(suiteName:)` rejects them.

## Step 4: Update tests

### Swift Testing

Swift Testing runs tests in parallel by default and creates a fresh suite instance per test, so store the helper as a property and clean up in `deinit` (requires the suite to be a class) or with `defer`.

```swift
import Testing
@testable import MyApp

final class SettingsTests {
    let testDefaults = TestDefaults()

    deinit { testDefaults.tearDown() }

    @Test func savesTheme() {
        let settings = Settings(defaults: testDefaults.defaults)
        settings.theme = .dark
        #expect(testDefaults.defaults.string(forKey: "theme") == "dark")
    }
}
```

### XCTest

```swift
import XCTest
@testable import MyApp

final class SettingsTests: XCTestCase {
    private var testDefaults: TestDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = TestDefaults(function: name)
    }

    override func tearDown() {
        testDefaults.tearDown()
        testDefaults = nil
        super.tearDown()
    }

    func testSavesTheme() {
        let settings = Settings(defaults: testDefaults.defaults)
        settings.theme = .dark
        XCTAssertEqual(testDefaults.defaults.string(forKey: "theme"), "dark")
    }
}
```

Remove any existing test code that clears keys on `UserDefaults.standard` in setup or teardown; it is no longer needed and is itself a source of cross-test interference.

## Step 5: Verify

- `grep -rn "UserDefaults.standard" <TestTarget>` returns nothing.
- Run the full test suite with parallel execution enabled (`swift test --parallel`, or enable "Execute in parallel" in the scheme's test plan) at least three times. All runs pass.
- Run tests in random order if the test plan supports it. All runs pass.
- After a run, no `tests.*.plist` files remain in the test host's Preferences directory.

## Out of scope

- `@AppStorage` in SwiftUI views. It accepts a `store:` parameter, but views are usually covered by UI tests or previews rather than unit tests. Flag any `@AppStorage` usages found in Step 1 in the summary, but do not refactor them unless they contain logic that existing unit tests cover.
- UI tests. Those should pass launch arguments (for example `-theme dark`) to override values through the argument domain instead.
- Replacing `UserDefaults` with a protocol and in-memory fake. Only do this if a type's tests need to avoid disk I/O entirely; mention it as a follow-up rather than doing it here.

## Deliverable

A short summary listing:

- Each production type changed and its new initializer signature.
- Each test file updated.
- Any `@AppStorage` usages found.
- Results of the parallel test runs.
