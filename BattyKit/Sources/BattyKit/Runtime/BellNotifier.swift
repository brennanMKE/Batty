// BellNotifier.swift

import AppKit
import Foundation
import UserNotifications

@MainActor
public protocol BellNotifying: AnyObject {
    /// `playSound` gates the request-level side of sound on top of the
    /// app-wide "Play sound" setting (`SettingsPreference.resolvedBellSound()`),
    /// which `post` still consults — `playSound: true` (bells, OSC 9/777)
    /// preserves the pre-#0284 behavior of "sound iff the toggle is on";
    /// `false` (CLI `notify` without `--sound`) suppresses sound for this
    /// call regardless of the toggle. Never the other way around: a caller
    /// cannot force sound past a disabled toggle.
    func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String,
        playSound: Bool
    )

    /// Posts a system notification not tied to a real Terminal Session —
    /// currently only the memory-footprint warning (#0290). `identifier`
    /// should be the paired Bell Feed entry's id so a tap routes through the
    /// same `onTapEntry` path as every other notification.
    func postFootprintWarning(title: String, body: String, identifier: String)
}

extension BellNotifying {
    /// Default no-op so test doubles that only exercise `post(for:...)`
    /// don't need updating for a path most of them don't touch.
    public func postFootprintWarning(title: String, body: String, identifier: String) {}
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

    /// #0297: `BellDecisionRecord.outcome` mirrors these two gates (and the
    /// nil-notifier / session-mute gates in `AppStateStore.postNotification`)
    /// by construction, not by sharing this method's implementation — only
    /// `evaluateShouldPost` below is actually shared. Adding a gate here
    /// (an `authorizationGranted` check is the obvious future candidate)
    /// without a matching case in `BellDecisionRecord.outcome` makes the
    /// #0297 decision history silently claim `outcome=submitted` for a
    /// bell this method actually suppressed. Update both in lockstep.
    public func post(
        for entry: BellFeedEntry,
        sessionTitle: String,
        paneIndex: Int,
        tabLabel: String,
        playSound: Bool = true
    ) {
        guard SettingsPreference.resolvedSystemNotifications() else { return }
        guard shouldPost(for: entry) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Batty — \(sessionTitle) › Pane \(paneIndex) › \(tabLabel)")
        content.body = entry.message?.isEmpty == false ? entry.message! : String(localized: "Bell")
        if playSound && SettingsPreference.resolvedBellSound() {
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
        Self.evaluateShouldPost(isBattyActive: NSApplication.shared.isActive, entrySeen: entry.seen)
    }

    /// Pure form of `shouldPost(for:)`'s gate, factored out for #0297: the
    /// bell-decision log needs to report this exact gate's verdict without
    /// duplicating the logic (and risking it drifting from the real
    /// decision). `isActive`/`entry.seen` are the only two inputs the
    /// instance method reads, so this is a straight extraction, not a
    /// behavior change.
    static func evaluateShouldPost(isBattyActive: Bool, entrySeen: Bool) -> Bool {
        if !isBattyActive { return true }
        return !entrySeen
    }

    /// Unlike `post(for:...)`, this fires only when Batty isn't frontmost —
    /// the Bell Feed entry (a `record()` call the caller makes alongside
    /// this) is the primary, always-visible warning surface (the unseen dot
    /// on the Bell Feed toolbar item); the system notification is the extra
    /// nudge for when the user isn't looking at the app at all. Firing it
    /// while Batty is active would duplicate a warning the user can already
    /// see.
    public func postFootprintWarning(title: String, body: String, identifier: String) {
        guard SettingsPreference.resolvedSystemNotifications() else { return }
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if SettingsPreference.resolvedBellSound() {
            content.sound = .default
        }
        content.userInfo = [Self.entryIdUserInfoKey: identifier]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
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
