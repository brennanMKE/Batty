// WorkspaceManager.swift

import AppKit
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "WorkspaceManager")

@Observable
public final class WorkspaceManager {
    public static let shared: WorkspaceManager = WorkspaceManager()

    public let store: AppStateStore
    public private(set) var lastSaveAt: Date?
    public private(set) var lastLoadResultDescription: String

    private let workspaceStore: WorkspaceStore?
    private var timerTask: Task<Void, Never>?
    private var willTerminateObserver: NSObjectProtocol?

    private init() {
        let resolvedStore: WorkspaceStore?
        do {
            resolvedStore = try WorkspaceStore()
        } catch {
            logger.error("could not resolve workspace store URL: \(error.localizedDescription, privacy: .public)")
            resolvedStore = nil
        }
        self.workspaceStore = resolvedStore

        // Launch always starts fresh: one window, one session, one pane, one tab,
        // one fresh shell prompt — matching Terminal.app / Ghostty / iTerm2 defaults.
        // The workspace file is still written for diagnostic purposes; bringing back
        // an opt-in "Restore Previous Layout" command later can re-enable the read.
        self.store = AppStateStore()
        self.lastLoadResultDescription = "skipped (launch starts fresh)"

        startTimer()
        observeAppLifecycle()
    }

    public func saveNow(sidebarHidden: Bool = false) {
        guard let workspaceStore else { return }
        let workspace = Workspace(
            windows: [WindowState(from: store, sidebarHidden: sidebarHidden)]
        )
        do {
            try workspaceStore.save(workspace)
            lastSaveAt = Date()
        } catch {
            logger.error("workspace save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                let hidden = UserDefaults.standard.bool(forKey: SidebarPreference.hiddenKey)
                self?.saveNow(sidebarHidden: hidden)
            }
        }
    }

    private func observeAppLifecycle() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let hidden = UserDefaults.standard.bool(forKey: SidebarPreference.hiddenKey)
                self?.saveNow(sidebarHidden: hidden)
                self?.store.nameCache.save()
            }
        }
    }

}
