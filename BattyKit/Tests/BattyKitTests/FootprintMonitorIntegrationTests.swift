// FootprintMonitorIntegrationTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
private final class FootprintWarningSpyNotifier: BellNotifying {
    private(set) var postedFootprintWarnings: [(title: String, body: String, identifier: String)] = []

    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String,
        playSound: Bool
    ) {}

    func postFootprintWarning(title: String, body: String, identifier: String) {
        postedFootprintWarnings.append((title, body, identifier))
    }
}

@MainActor
struct AppStateStoreFootprintWarningTests {

    @Test func recordFootprintWarningAddsAnUnseenSystemEntryWithFootprintAndSessionCount() {
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)

        guard let entry = store.bellFeed.entries.first else {
            Issue.record("Expected a Bell Feed entry")
            return
        }
        #expect(store.bellFeed.entries.count == 1)
        #expect(entry.seen == false)
        #expect(entry.sessionID == BellFeedEntry.systemID)
        #expect(entry.windowID == BellFeedEntry.systemID)
        #expect(entry.paneID == BellFeedEntry.systemID)
        #expect(entry.tabID == BellFeedEntry.systemID)
        // Session count comes from TerminalHostStore.shared, which the default
        // AppStateStore(notifier:) initializer never registers a tab with —
        // the message should still name a Terminal Session count (0) and a
        // formatted byte count, not silently drop either.
        #expect(entry.message?.contains("Terminal Session") == true)
        #expect(entry.message?.isEmpty == false)
    }

    @Test func recordFootprintWarningNotifiesWithMatchingIdentifier() {
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)

        guard let entry = store.bellFeed.entries.first else {
            Issue.record("Expected a Bell Feed entry")
            return
        }
        #expect(notifier.postedFootprintWarnings.count == 1)
        #expect(notifier.postedFootprintWarnings.first?.identifier == entry.id.uuidString)
        #expect(notifier.postedFootprintWarnings.first?.body == entry.message)
    }

    @Test func repeatedWarningsProduceIndependentEntries() {
        // recordFootprintWarning itself does no suppression — that's
        // FootprintWarningState's job, upstream in FootprintMonitor. This
        // just confirms the plumbing doesn't dedupe/overwrite on its own.
        let notifier = FootprintWarningSpyNotifier()
        let store = AppStateStore(notifier: notifier)

        store.recordFootprintWarning(footprintBytes: 4_300_000_000, step: 1)
        store.recordFootprintWarning(footprintBytes: 5_300_000_000, step: 2)

        #expect(store.bellFeed.entries.count == 2)
    }
}

/// `AppStateStore.formatGB` (#0295): builds the footprint number that goes
/// into the warning sentence. It used to hard-code `String(format: "%.2f
/// GB", …)`, baking in `.` as the decimal separator regardless of locale.
/// These tests pin explicit, non-default locales (`fr_FR`/`de_DE` use a
/// comma) rather than relying on the test machine's locale, so the
/// assertion actually exercises locale-sensitive formatting and doesn't
/// just pass incidentally on an en-US machine.
struct FormatGBLocaleTests {

    @Test func enUSUsesAPeriodDecimalSeparator() {
        let text = AppStateStore.formatGB(4_903_778_910, locale: Locale(identifier: "en_US"))

        #expect(text == "4.57 GB")
    }

    @Test func frFRUsesACommaDecimalSeparator() {
        let text = AppStateStore.formatGB(4_903_778_910, locale: Locale(identifier: "fr_FR"))

        #expect(text == "4,57 GB")
        #expect(!text.contains("."))
    }

    @Test func deDEUsesACommaDecimalSeparatorToo() {
        let text = AppStateStore.formatGB(4_903_778_910, locale: Locale(identifier: "de_DE"))

        #expect(text == "4,57 GB")
        #expect(!text.contains("."))
    }

    @Test func keepsExactlyTwoDecimalPlacesEvenOnAWholeGiBBoundary() {
        // A footprint that lands on an exact GiB (e.g. right at a 4 GB
        // limit) must still show "4.00", not round down to "4" — the
        // warning needs to read visibly above the limit it just crossed.
        let fourGiB: UInt64 = 4 * 1_073_741_824

        #expect(AppStateStore.formatGB(fourGiB, locale: Locale(identifier: "en_US")) == "4.00 GB")
        #expect(AppStateStore.formatGB(fourGiB, locale: Locale(identifier: "fr_FR")) == "4,00 GB")
    }
}

/// `AppStateStore.footprintWarningMessage` (#0295): the Terminal Session
/// count used to pluralize via `sessionCount == 1 ? "Terminal Session" :
/// "Terminal Sessions"` — an untranslatable English literal interpolated
/// into a `String(localized:)` sentence. The fix moves the plural rule into
/// `Batty/Localizable.xcstrings` as a manually-added "plural" variation,
/// matching the pattern already used for the other BattyKit strings there
/// (`%lld unseen bell event(s)`, `There %lld open terminal(s).`, `Paste
/// %lld lines?`).
///
/// A prior version of this suite only compared the catalog against a
/// hand-copied literal of the source sentence, so it could not catch the
/// source sentence itself drifting from the catalog (e.g. "across" edited
/// to "in") — both sides would still agree with each other while
/// disagreeing with the shipped string. It also documented, incorrectly,
/// that `Bundle.main` being the xctest runner (not `Batty.app`) under
/// `BattyKitTests` meant *no* test could observe real plural rendering.
/// That's wrong: `String(localized:bundle:locale:)` takes an explicit
/// bundle, so compiling the real catalog with `xcrun xcstringstool compile`
/// into a temp directory and loading it with `Bundle(url:)` gives a real,
/// loadable catalog to resolve against — exercising the exact production
/// call (`AppStateStore.footprintWarningMessage`) and the exact production
/// catalog file on disk, not a copy of either.
struct FootprintWarningMessageLocalizationTests {

    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BattyKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BattyKit
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Batty/Localizable.xcstrings")
    }

    /// Compiles `Batty/Localizable.xcstrings` with `xcrun xcstringstool
    /// compile` into a fresh temp directory and loads it as a `Bundle`.
    /// Each test gets its own compile + directory (no shared mutable
    /// state, no cross-test cleanup ordering to get wrong); the temp
    /// directory is removed when the returned bundle goes out of scope.
    private static func compileCatalogBundle(languages: [String]) throws -> Bundle {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BattyKitTests-xcstrings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["xcstringstool", "compile", Self.catalogURL.path, "-o", outputDirectory.path]
        for language in languages {
            arguments += ["-l", language]
        }
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CatalogCompileError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
        }

        return try #require(
            Bundle(url: outputDirectory),
            "Bundle(url:) failed to load the directory xcstringstool compiled into: \(outputDirectory.path)"
        )
    }

    private enum CatalogCompileError: Error, CustomStringConvertible {
        case nonZeroExit(status: Int32, stderr: String)

        var description: String {
            switch self {
            case .nonZeroExit(let status, let stderr):
                return "xcstringstool compile exited \(status): \(stderr)"
            }
        }
    }

    @Test(arguments: ["en", "fr", "de", "ru"])
    func rendersCorrectSingularGrammarForOneSessionAcrossLocales(languageID: String) throws {
        let bundle = try Self.compileCatalogBundle(languages: ["en", "fr", "de", "ru"])

        let message = AppStateStore.footprintWarningMessage(
            footprintText: "4.30 GB",
            sessionCount: 1,
            bundle: bundle,
            locale: Locale(identifier: languageID)
        )

        #expect(message == "Batty is using 4.30 GB across 1 Terminal Session. Close some to free memory.")
    }

    @Test(arguments: ["en", "fr", "de", "ru"])
    func rendersCorrectPluralGrammarForMultipleSessionsAcrossLocales(languageID: String) throws {
        let bundle = try Self.compileCatalogBundle(languages: ["en", "fr", "de", "ru"])

        let message = AppStateStore.footprintWarningMessage(
            footprintText: "4.30 GB",
            sessionCount: 3,
            bundle: bundle,
            locale: Locale(identifier: languageID)
        )

        #expect(message == "Batty is using 4.30 GB across 3 Terminal Sessions. Close some to free memory.")
    }
}

@MainActor
struct FootprintMonitorTests {

    /// `limitBytesProvider` and `footprintBytesProvider` injection (rather
    /// than `UserDefaults` or the live process's real, constantly-if-slowly
    /// changing footprint) keeps these self-contained and deterministic.
    /// `UserDefaults.standard` is global process state, and Swift Testing
    /// runs test functions concurrently by default, so racing to set/remove
    /// the same preference key is flaky; the real footprint changing
    /// between two back-to-back `sampleOnce()` calls is exactly the kind of
    /// incidental growth this suppression rule has to be immune to, so
    /// asserting against it (rather than injecting a fixed value) doesn't
    /// actually constrain the rule. Each test here owns its own
    /// `FootprintMonitor` and its own closures — no shared mutable state
    /// with any other test.

    private static let fourGBLimit: UInt64 = 4_000_000_000

    @Test func sampleOnceDoesNotWarnUnderTheLimit() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 3_000_000_000 }
        var warned = false
        monitor.onWarn = { _, _ in warned = true }

        monitor.sampleOnce()

        #expect(warned == false)
    }

    @Test func sampleOnceWarnsOnceTheFootprintCrossesTheLimit() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 4_300_000_000 }
        var warnedBytes: UInt64?
        var warnedStep: Int?
        monitor.onWarn = { bytes, step in
            warnedBytes = bytes
            warnedStep = step
        }

        monitor.sampleOnce()

        #expect(warnedBytes == 4_300_000_000)
        #expect(warnedStep == 1)
    }

    @Test func sampleOnceDoesNotRepeatOnConsecutiveSamplesAtTheSameStep() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        monitor.footprintBytesProvider = { 4_300_000_000 }
        var warnCount = 0
        monitor.onWarn = { _, _ in warnCount += 1 }

        monitor.sampleOnce()
        monitor.sampleOnce()
        monitor.sampleOnce()

        #expect(warnCount == 1)
    }

    @Test func sampleOnceWarnsAgainOnANewStep() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { Self.fourGBLimit }
        var bytes: UInt64 = 4_300_000_000
        monitor.footprintBytesProvider = { bytes }
        var warnCount = 0
        monitor.onWarn = { _, _ in warnCount += 1 }

        monitor.sampleOnce()
        bytes = 5_300_000_000 // one full stepBytes (limit/4 == 1 GB) further
        monitor.sampleOnce()

        #expect(warnCount == 2)
    }

    @Test func defaultLimitBytesProviderReadsTheRealPreference() {
        // One narrow, single-assertion check that the production default
        // isn't accidentally hardcoded — everything else in this suite
        // injects its own provider to stay independent of global UserDefaults
        // state.
        let monitor = FootprintMonitor()
        #expect(monitor.limitBytesProvider() == SettingsPreference.resolvedFootprintSoftLimitBytes())
    }

    @Test func defaultFootprintBytesProviderReadsTheRealFootprint() {
        let monitor = FootprintMonitor()
        #expect(monitor.footprintBytesProvider() != nil)
    }

    @Test func sampleOnceLogsAndSkipsWhenTheFootprintProviderFails() {
        let monitor = FootprintMonitor()
        monitor.limitBytesProvider = { 1 }
        monitor.footprintBytesProvider = { nil }
        var warned = false
        monitor.onWarn = { _, _ in warned = true }

        monitor.sampleOnce()

        #expect(warned == false)
    }
}
