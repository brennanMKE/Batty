// SidebarFooterTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
struct SidebarFooterTests {
    private func makeStore(projectsEnabled: Bool, in directory: URL) -> AppStateStore {
        AppStateStore(
            nameCache: SessionNameCache(fileURL: directory.appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projectsEnabled),
            projectsFileURL: directory.appendingPathComponent("projects.json")
        )
    }

    private func withTempDirectory(_ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batty-footer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory)
    }

    @Test func buttonShownOnlyWithFlagOn() {
        #expect(SidebarFooter.showsOpenProjectButton(featureFlags: FeatureFlags(projects: true)))
        #expect(!SidebarFooter.showsOpenProjectButton(featureFlags: FeatureFlags(projects: false)))
    }

    @Test func literalsArePinned() {
        #expect(SidebarFooter.openProjectSystemName == "briefcase")
        #expect(SidebarFooter.openProjectIdentifier == "session-sidebar.open-project-button")
        #expect(SidebarFooter.addSessionIdentifier == "session-sidebar.add-session-button")
        #expect(SidebarFooter.openProjectHelp == "Open Project\u{2026}")
        #expect(SidebarFooter.openProjectLabel == "Open Project")
    }

    @Test func symbolResolvesAndAvoidsNeighbours() {
        let name = SidebarFooter.openProjectSystemName
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        for taken in ["plus", "folder", "folder.fill", "folder.badge.plus"] {
            #expect(name != taken)
        }
        #expect(!ProjectSymbol.allCases.map(\.systemName).contains(name))
    }

    @Test func presentingTargetsOnlyTheClickedWindow() {
        withTempDirectory { directory in
            let store = makeStore(projectsEnabled: true, in: directory)
            let w1 = store.windows[0]
            let w2 = store.windowRuntime(for: WindowID())
            #expect(!w1.projectPickerShown && !w2.projectPickerShown)

            SidebarFooter.presentProjectPicker(in: w1, featureFlags: store.featureFlags)
            #expect(w1.projectPickerShown)
            #expect(!w2.projectPickerShown)

            SidebarFooter.presentProjectPicker(in: w2, featureFlags: store.featureFlags)
            #expect(w1.projectPickerShown)
            #expect(w2.projectPickerShown)
        }
    }

    @Test func flagOffPresentsNothingAndNeverConstructsTheProjectStore() {
        withTempDirectory { directory in
            let store = makeStore(projectsEnabled: false, in: directory)
            let window = store.windows[0]

            SidebarFooter.presentProjectPicker(in: window, featureFlags: store.featureFlags)

            #expect(!window.projectPickerShown)
            #expect(!store.projectStoreIsConstructed)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("projects.json").path))
        }
    }
}
