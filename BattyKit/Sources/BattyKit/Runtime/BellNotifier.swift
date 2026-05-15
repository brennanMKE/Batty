// BellNotifier.swift

import AppKit
import Foundation
import UserNotifications

@MainActor
public protocol BellNotifying: AnyObject {
    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String
    )
}

@MainActor
public final class BellNotifier: BellNotifying {
    public static let entryIdUserInfoKey = "co.sstools.Batty.bellEntryID"

    private let center: UNUserNotificationCenter
    private let delegate: BellNotifierDelegate
    private var hasRequestedAuthorization: Bool = false
    private var authorizationGranted: Bool = false

    public init(
        center: UNUserNotificationCenter = .current(),
        onTapEntry: @escaping (UUID) -> Void = { _ in }
    ) {
        self.center = center
        self.delegate = BellNotifierDelegate(onTapEntry: onTapEntry)
        center.delegate = delegate
    }

    public func ensureAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.authorizationGranted = granted
            }
        }
    }

    public func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String
    ) {
        guard SettingsPreference.resolvedSystemNotifications() else { return }
        guard shouldPost(for: entry) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Batty — \(sessionTitle) › Pane \(paneIndex) › \(tabLabel)")
        content.body = entry.message?.isEmpty == false ? entry.message! : String(localized: "Bell")
        if SettingsPreference.resolvedBellSound() {
            content.sound = .default
        }
        content.userInfo = [Self.entryIdUserInfoKey: entry.id.uuidString]

        let request = UNNotificationRequest(
            identifier: entry.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    private func shouldPost(for entry: BellFeedEntry) -> Bool {
        if !NSApplication.shared.isActive { return true }
        return !entry.seen
    }
}

private final class BellNotifierDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let onTapEntry: (UUID) -> Void

    init(onTapEntry: @escaping (UUID) -> Void) {
        self.onTapEntry = onTapEntry
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let raw = userInfo[BellNotifier.entryIdUserInfoKey] as? String,
           let id = UUID(uuidString: raw) {
            let handler = onTapEntry
            DispatchQueue.main.async {
                handler(id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
