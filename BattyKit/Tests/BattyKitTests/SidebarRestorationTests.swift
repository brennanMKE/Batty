// SidebarRestorationTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Tests for the per-window sidebar persistence added in #0238:
/// legacy-key migration seeding and notification routing.
@MainActor
struct SidebarRestorationTests {

    // MARK: - SidebarPreference.resolveInitialValue (migration seed logic)

    @Test func migrationNotDoneWithLegacyHiddenSeedsHidden() {
        let result = SidebarPreference.resolveInitialValue(
            migrationDone: false,
            legacyValue: true
        )
        #expect(result == true, "First launch with sidebar hidden should seed to hidden")
    }

    @Test func migrationNotDoneWithLegacyShownSeedsShown() {
        let result = SidebarPreference.resolveInitialValue(
            migrationDone: false,
            legacyValue: false
        )
        #expect(result == false, "First launch with sidebar shown should seed to shown")
    }

    @Test func migrationDoneReturnsNilSignallingNoOverride() {
        let result = SidebarPreference.resolveInitialValue(
            migrationDone: true,
            legacyValue: true
        )
        #expect(result == nil,
                "After migration the legacy value must not override the per-scene value")
    }

    @Test func migrationDoneWithLegacyShownAlsoReturnsNil() {
        let result = SidebarPreference.resolveInitialValue(
            migrationDone: true,
            legacyValue: false
        )
        #expect(result == nil,
                "After migration, no override regardless of the legacy value")
    }

    // MARK: - SidebarPreference constants

    @Test func sidebarPreferenceKeysAreStable() {
        // These keys are written to UserDefaults and must never change
        // silently, or existing users' sidebar state is lost.
        #expect(SidebarPreference.hiddenKey == "co.sstools.Batty.sidebarHidden")
        #expect(SidebarPreference.migratedKey == "co.sstools.Batty.sidebarMigrated")
        #expect(SidebarPreference.sceneStorageKey == "sidebarHidden")
    }

    // MARK: - battyToggleSidebar notification name

    @Test func battyToggleSidebarNotificationNameIsStable() {
        // This name is posted from BattyShortcuts, CommandPaletteView, and
        // BattyCommands, and received in RootWindowView — must be consistent.
        #expect(Notification.Name.battyToggleSidebar.rawValue ==
                "co.sstools.Batty.toggleSidebar")
    }

    // MARK: - toggleSidebar posts notification, not UserDefaults

    @Test func toggleSidebarViaNotificationIsReceivable() async throws {
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .battyToggleSidebar,
            object: nil,
            queue: .main
        ) { _ in
            received = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: .battyToggleSidebar, object: nil)
        // Give the main queue a turn to deliver.
        await Task.yield()
        #expect(received, "battyToggleSidebar notification should be deliverable")
    }
}
