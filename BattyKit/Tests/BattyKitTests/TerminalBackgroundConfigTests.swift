// TerminalBackgroundConfigTests.swift

import Foundation
import GhosttyTerminal
import Testing
@testable import BattyKit

/// `renderedConfig` only reflects a config libghostty's own diagnostics
/// accepted (`prepareConfig` fails closed), so these run against the real
/// bundled binary: a green `contains` is proof the pinned version accepted the
/// key, not just proof of string formatting.
/// `misspelledBackgroundKeyIsRejected` is the control showing the check can fail.
///
/// Lines are matched exactly because `background-image` is a prefix of its
/// siblings.
@MainActor
final class TerminalBackgroundConfigTests {
    private static let imagePath = "/tmp/batty-background-tests/photo.png"
    private static let configuredLines = [
        "background-image = \"\(imagePath)\"",
        "background-image-fit = cover",
        "background-image-position = top-left",
        "background-image-opacity = 0.35",
        "background-opacity = 0.5",
    ]

    private let testDefaults = TestDefaults()
    private var defaults: UserDefaults { testDefaults.defaults }

    @MainActor deinit { testDefaults.tearDown() }

    private func configureEverything() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set("cover", forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set("top-left", forKey: SettingsPreference.backgroundImagePositionKey)
        defaults.set(0.35, forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set(0.5, forKey: SettingsPreference.backgroundOpacityKey)
    }

    private func lines(_ tab: TabRuntime) -> [String] {
        tab.terminal.renderedConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func backgroundLines(_ tab: TabRuntime) -> [String] {
        lines(tab).filter { $0.hasPrefix("background-") }
    }

    private var gate: AppWideBackgroundGate { .acceptingEveryImage(defaults: defaults) }

    private func tab() -> TabRuntime {
        TabRuntime(backgroundGate: gate)
    }

    private func allTabs(_ store: AppStateStore) -> [TabRuntime] {
        store.windows.flatMap(\.sessions).flatMap { $0.tree.allPanes.flatMap(\.tabs) }
    }

    /// A store whose appearance push has run against `defaults`.
    private func appliedStore() -> AppStateStore {
        let store = AppStateStore(preferences: defaults, backgroundGate: gate)
        store.applyAppearanceToAllSurfaces()
        #expect(!allTabs(store).isEmpty)
        return store
    }

    // MARK: - Emission

    @Test func tabBuilderEmitsConfiguredBackgroundLines() {
        configureEverything()
        let tab = tab()
        #expect(backgroundLines(tab) == Self.configuredLines)
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
    }

    @Test func attachContextKeepsBackgroundLines() {
        configureEverything()
        let tab = tab()
        let paneID = UUID()
        tab.attachContext(paneID: paneID, sessionID: UUID())
        #expect(lines(tab).contains("env = BATTY_PANE_ID=\(paneID.uuidString)"))
        #expect(backgroundLines(tab) == Self.configuredLines)
    }

    @Test func appearancePushEmitsConfiguredBackgroundLines() {
        configureEverything()
        let store = AppStateStore(preferences: defaults, backgroundGate: gate)
        _ = store.windowRuntime(for: WindowID())
        #expect(store.windows.count >= 2)
        store.applyAppearanceToAllSurfaces()
        for window in store.windows {
            let tabs = window.sessions.flatMap { $0.tree.allPanes.flatMap(\.tabs) }
            #expect(!tabs.isEmpty)
            for tab in tabs {
                #expect(backgroundLines(tab) == Self.configuredLines)
                #expect(tab.terminal.controller.lastConfigurationIssue == nil)
            }
        }
    }

    @Test func newAndPushedTabsEmitIdenticalBackgroundLines() {
        configureEverything()
        let fromTab = backgroundLines(tab())
        #expect(!fromTab.isEmpty)
        for tab in allTabs(appliedStore()) {
            #expect(backgroundLines(tab) == fromTab)
        }
    }

    @Test func unsetPreferencesEmitNoBackgroundLines() {
        #expect(backgroundLines(tab()).isEmpty)
        for tab in allTabs(appliedStore()) {
            #expect(backgroundLines(tab).isEmpty)
        }
    }

    @Test func terminalOpacityOfOneEmitsNothing() {
        defaults.set(1.0, forKey: SettingsPreference.backgroundOpacityKey)
        #expect(backgroundLines(tab()).isEmpty)
    }

    @Test func opacityOfZeroIsEmittedNotTreatedAsUnset() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set(0.0, forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set(0.0, forKey: SettingsPreference.backgroundOpacityKey)
        let lines = lines(tab())
        #expect(lines.contains("background-image-opacity = 0.0"))
        #expect(lines.contains("background-opacity = 0"))
    }

    @Test func fitAndPositionWithoutAnImageEmitNothing() {
        defaults.set("cover", forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set("top-left", forKey: SettingsPreference.backgroundImagePositionKey)
        defaults.set(0.35, forKey: SettingsPreference.backgroundImageOpacityKey)
        #expect(backgroundLines(tab()).isEmpty)
    }

    @Test func clearingTheImageRemovesItsLines() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        let store = appliedStore()
        for tab in allTabs(store) {
            #expect(lines(tab).contains("background-image = \"\(Self.imagePath)\""))
        }
        defaults.removeObject(forKey: SettingsPreference.backgroundImagePathKey)
        store.applyAppearanceToAllSurfaces()
        for tab in allTabs(store) {
            #expect(backgroundLines(tab).isEmpty)
        }
    }

    @Test func opacitiesClampOnlyWhereLibghosttyRequiresIt() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set(1.5, forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set(1.5, forKey: SettingsPreference.backgroundOpacityKey)
        let tab = tab()
        #expect(lines(tab).contains("background-image-opacity = 1.5"))
        #expect(!lines(tab).contains { $0.hasPrefix("background-opacity") })
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
    }

    // MARK: - The replace hazard

    @Test func appearanceChangeKeepsTheBackground() {
        configureEverything()
        let store = appliedStore()
        defaults.set(21.0, forKey: SettingsPreference.fontSizeKey)
        store.applyAppearanceToAllSurfaces()
        for tab in allTabs(store) {
            #expect(lines(tab).contains("font-size = 21"))
            #expect(backgroundLines(tab) == Self.configuredLines)
        }
    }

    @Test func sharedPreferencesReachNewAndPushedTabs() {
        let path = TabRuntimeCLIPathSeam.injectedPath(
            basePath: ProcessInfo.processInfo.environment["PATH"],
            bundlePath: Bundle.main.bundlePath
        )
        let expected = [
            "shell-integration-features = ssh-env",
            "env = PATH=\(path)",
            "keybind = super+left=text:\\x01",
            "keybind = super+right=text:\\x05",
            "keybind = super+backspace=text:\\x15",
            "keybind = alt+left=text:\\x1bb",
            "keybind = alt+right=text:\\x1bf",
            "keybind = alt+backspace=text:\\x1b\\x7f",
        ]
        let tabs = [tab()] + allTabs(appliedStore())
        for tab in tabs {
            let lines = lines(tab)
            for line in expected {
                #expect(lines.contains(line), "missing \(line)")
            }
        }
    }

    /// `keybind = clear` removes every binding before it. If the shared helper
    /// moved above it in `TabRuntime`, the six shared bindings would still be in
    /// the rendered config but would have no effect, so only their order shows it.
    @Test func perTabKeybindClearPrecedesEveryOtherKeybind() throws {
        let keybinds = lines(tab()).filter { $0.hasPrefix("keybind = ") }
        #expect(keybinds.first == "keybind = clear")
        let clearIndex = try #require(keybinds.firstIndex(of: "keybind = clear"))
        for binding in [
            "keybind = super+left=text:\\x01",
            "keybind = super+right=text:\\x05",
            "keybind = super+backspace=text:\\x15",
            "keybind = alt+left=text:\\x1bb",
            "keybind = alt+right=text:\\x1bf",
            "keybind = alt+backspace=text:\\x1b\\x7f",
        ] {
            let index = try #require(keybinds.firstIndex(of: binding), "missing \(binding)")
            #expect(index > clearIndex, "\(binding) precedes keybind = clear")
        }
    }

    // MARK: - Harness and validation

    @Test func misspelledBackgroundKeyIsRejected() {
        let tab = tab()
        let before = tab.terminal.renderedConfig
        let accepted = tab.terminal.controller.setTerminalConfiguration(
            TerminalConfiguration { builder in
                builder.withCustom("background-imag", Self.imagePath)
            }
        )
        #expect(!accepted)
        #expect(tab.terminal.controller.lastConfigurationIssue?.contains("unknown field") == true)
        #expect(tab.terminal.renderedConfig == before)
    }

    @Test func everyFitAndPositionIsAcceptedByLibghostty() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        for fit in BackgroundImageFit.allCases {
            defaults.set(fit.rawValue, forKey: SettingsPreference.backgroundImageFitKey)
            let tab = tab()
            #expect(lines(tab).contains("background-image-fit = \(fit.rawValue)"))
            #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        }
        for position in BackgroundImagePosition.allCases {
            defaults.set(position.rawValue, forKey: SettingsPreference.backgroundImagePositionKey)
            let tab = tab()
            #expect(lines(tab).contains("background-image-position = \(position.rawValue)"))
            #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        }
    }

    @Test func unknownStoredFitAndPositionFallBackAndKeepOtherOverrides() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set("bogus", forKey: SettingsPreference.backgroundImageFitKey)
        defaults.set("middle", forKey: SettingsPreference.backgroundImagePositionKey)
        let tab = tab()
        let lines = lines(tab)
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        #expect(lines.contains("background-image-fit = contain"))
        #expect(lines.contains("background-image-position = center"))
        #expect(lines.contains { $0.hasPrefix("font-size = ") })
    }

    /// Pins the measured behavior #0375 builds on: libghostty doesn't check
    /// the path at config time, so a missing file costs no other override.
    @Test func missingImagePathKeepsEveryOtherOverride() {
        let missing = "/tmp/batty-background-tests/\(UUID().uuidString)/gone.png"
        defaults.set(missing, forKey: SettingsPreference.backgroundImagePathKey)
        let tab = tab()
        let lines = lines(tab)
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        #expect(lines.contains("background-image = \"\(missing)\""))
        #expect(lines.contains { $0.hasPrefix("font-size = ") })
        #expect(lines.contains("keybind = super+left=text:\\x01"))
        #expect(lines.contains("env = BATTY_TAB_ID=\(tab.id.uuidString)"))
    }

    @Test func pathWithSpacesIsEmittedQuoted() {
        for path in ["/tmp/batty background tests/my photo.png", "/tmp/batty \"quoted\" #1.png"] {
            defaults.set(path, forKey: SettingsPreference.backgroundImagePathKey)
            let tab = tab()
            #expect(tab.terminal.controller.lastConfigurationIssue == nil)
            #expect(lines(tab).contains("background-image = \"\(path)\""))
        }
    }

    @Test func tildePathIsExpanded() {
        defaults.set("~/batty-background-tests/photo.png", forKey: SettingsPreference.backgroundImagePathKey)
        let expanded = ("~/batty-background-tests/photo.png" as NSString).expandingTildeInPath
        #expect(expanded.hasPrefix("/"))
        #expect(lines(tab()).contains("background-image = \"\(expanded)\""))
    }

    @Test func relativeOrControlCharacterPathEmitsNoImage() {
        for path in ["photos/background.png", "/tmp/a.png\nkeybind = cmd+q=quit"] {
            defaults.set(path, forKey: SettingsPreference.backgroundImagePathKey)
            let tab = tab()
            #expect(tab.terminal.controller.lastConfigurationIssue == nil)
            #expect(backgroundLines(tab).isEmpty)
            #expect(!lines(tab).contains { $0.contains("cmd+q") })
        }
    }

    @Test func nonFiniteOpacitiesFallBackToOff() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        for value in [Double.nan, .infinity] {
            defaults.set(value, forKey: SettingsPreference.backgroundImageOpacityKey)
            defaults.set(value, forKey: SettingsPreference.backgroundOpacityKey)
            let lines = lines(tab())
            #expect(lines.contains("background-image-opacity = 1.0"))
            #expect(!lines.contains { $0.hasPrefix("background-opacity") })
        }
    }

    // MARK: - Opacity on painted cells

    @Test func cellOpacityIsEmittedWithTheToggleBelowFullOpacity() {
        defaults.set(0.5, forKey: SettingsPreference.backgroundOpacityKey)
        defaults.set(true, forKey: SettingsPreference.backgroundOpacityCellsKey)
        let tab = tab()
        #expect(lines(tab).contains("background-opacity-cells = true"))
        #expect(tab.terminal.controller.lastConfigurationIssue == nil)
        for storeTab in allTabs(appliedStore()) {
            #expect(lines(storeTab).contains("background-opacity-cells = true"))
        }
    }

    @Test func cellOpacityEmitsNothingAtFullOpacityOrToggleOff() {
        defaults.set(true, forKey: SettingsPreference.backgroundOpacityCellsKey)
        defaults.set(1.0, forKey: SettingsPreference.backgroundOpacityKey)
        #expect(backgroundLines(tab()).isEmpty)
        defaults.set(0.5, forKey: SettingsPreference.backgroundOpacityKey)
        defaults.set(false, forKey: SettingsPreference.backgroundOpacityCellsKey)
        #expect(backgroundLines(tab()) == ["background-opacity = 0.5"])
    }

    // MARK: - Hardening and legibility

    @Test func nonNumericOpacityFallsBackToTheDefault() {
        defaults.set(Self.imagePath, forKey: SettingsPreference.backgroundImagePathKey)
        defaults.set("loud", forKey: SettingsPreference.backgroundImageOpacityKey)
        defaults.set("loud", forKey: SettingsPreference.backgroundOpacityKey)
        let lines = lines(tab())
        #expect(lines.contains("background-image-opacity = 1.0"))
        #expect(!lines.contains { $0.hasPrefix("background-opacity") })
    }

    /// Blends as `bg_image_fragment` does, over the worst possible images.
    @Test func firstImageTintKeepsDefaultThemesReadable() throws {
        let black = RGBColor(red: 0, green: 0, blue: 0, alpha: 1)
        let white = RGBColor(red: 1, green: 1, blue: 1, alpha: 1)
        for name in [ThemePreference.defaultDarkThemeName, ThemePreference.defaultLightThemeName] {
            let theme = try #require(BattyThemeCatalog.theme(named: name))
            let background = try #require(RGBColor(hex: theme.background))
            let foreground = try #require(RGBColor(hex: theme.foreground))
            for image in [black, white] {
                let blended = background.blended(with: image, ratio: TerminalBackgroundSettings.firstImageOpacity)
                #expect(foreground.contrast(against: blended) >= 3, "\(name)")
            }
        }
    }
}
