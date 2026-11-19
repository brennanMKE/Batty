// PendingClipboardConfirmation.swift

import Foundation
import GhosttyTerminal
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PendingClipboardConfirmation")

/// Where a clipboard request came from, resolved from the requesting Tab
/// when it arrives. Upstream's `TerminalClipboardConfirmationRequest` names
/// no program, so `processName` is the Pane's foreground process at that
/// moment — best effort, normally the sender.
public struct ClipboardRequestContext: Sendable, Equatable {
    public var sessionID: UUID?
    public var sessionTitle: String?
    public var tabID: UUID
    public var paneID: UUID?
    public var paneIndex: Int?
    public var tabLabel: String?
    public var processName: String?
    public var pid: Int32?

    public init(
        sessionID: UUID? = nil,
        sessionTitle: String? = nil,
        tabID: UUID,
        paneID: UUID? = nil,
        paneIndex: Int? = nil,
        tabLabel: String? = nil,
        processName: String? = nil,
        pid: Int32? = nil
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.tabID = tabID
        self.paneID = paneID
        self.paneIndex = paneIndex
        self.tabLabel = tabLabel
        self.processName = processName
        self.pid = pid
    }

    public static func unresolved(tabID: UUID) -> ClipboardRequestContext {
        ClipboardRequestContext(tabID: tabID)
    }
}

/// How a clipboard request was decided, for the log line.
public enum ClipboardDecisionReason: String, Sendable {
    case settingAllow = "setting-allow"
    case settingNever = "setting-never"
    case remembered
    case coalesced
    /// Answered in the dialog, dismissed, or denied by a Session switch.
    case dialog
    case noSession = "no-session"
}

/// Captured when a terminal program needs the user's explicit permission for
/// a clipboard operation — an unsafe paste, or a protected OSC 52 read/write.
/// The view layer presents the dialog; the owning `SessionRuntime` answers it
/// via `decide`, which resolves the wrapper's request exactly once
/// (`TerminalSurfaceClipboardConfirmationDelegate`'s contract). `context`
/// names the Session, Pane, Tab and foreground program when they resolved.
public struct PendingClipboardConfirmation: Identifiable {
    public let id = UUID()
    let kind: TerminalClipboardRequestKind
    let context: ClipboardRequestContext?
    let decide: (Bool) -> Void

    init(kind: TerminalClipboardRequestKind, context: ClipboardRequestContext? = nil, decide: @escaping (Bool) -> Void) {
        self.kind = kind
        self.context = context
        self.decide = decide
    }

    public var title: String {
        String(localized: "Allow Clipboard Access?")
    }

    public var message: String {
        Self.message(kind: kind, context: context)
    }

    static func message(kind: TerminalClipboardRequestKind, context: ClipboardRequestContext?) -> String {
        guard let context, let location = location(context) else {
            switch kind {
            case .paste:
                return String(localized: "A terminal program wants to paste clipboard contents that may be unsafe.")
            case .osc52Read:
                return String(localized: "A terminal program wants to read the clipboard.")
            case .osc52Write:
                return String(localized: "A terminal program wants to write to the clipboard.")
            }
        }
        let who: String
        if let name = context.processName, !name.isEmpty {
            who = String(localized: "\u{201C}\(name)\u{201D} in \(location)")
        } else {
            who = String(localized: "A program in \(location)")
        }
        switch kind {
        case .paste:
            return String(localized: "\(who) wants to paste clipboard contents that may be unsafe.")
        case .osc52Read:
            return String(localized: "\(who) wants to read the clipboard.")
        case .osc52Write:
            return String(localized: "\(who) wants to write to the clipboard.")
        }
    }

    private static func location(_ context: ClipboardRequestContext) -> String? {
        var parts: [String] = []
        if let title = context.sessionTitle { parts.append("\u{201C}\(title)\u{201D}") }
        if let index = context.paneIndex { parts.append(String(localized: "Pane \(index)")) }
        if let label = context.tabLabel, !label.isEmpty { parts.append(label) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{203A} ")
    }
}

private func kindName(_ kind: TerminalClipboardRequestKind) -> String {
    switch kind {
    case .paste: "paste"
    case .osc52Read: "osc52Read"
    case .osc52Write: "osc52Write"
    }
}

private final class ReasonBox {
    var reason: ClipboardDecisionReason = .dialog
}

/// Applies the app-wide read Setting, then the owning Session's per-kind
/// policy, and logs every decision once. A request whose owning Session
/// cannot be resolved (the tab's Session isn't attached yet, or the tab
/// closed before `PaneView`'s wiring ran) denies, never hangs and never
/// defaults to allow. `readPolicy` applies only to `.osc52Read`.
func routeClipboardConfirmation(
    to session: SessionRuntime?,
    kind: TerminalClipboardRequestKind,
    readPolicy: ClipboardReadPolicy,
    context: ClipboardRequestContext,
    decide: @escaping (Bool) -> Void
) {
    let box = ReasonBox()
    let logged: (Bool) -> Void = { allowed in
        logger.notice("clipboard kind=\(kindName(kind), privacy: .public) allowed=\(allowed, privacy: .public) reason=\(box.reason.rawValue, privacy: .public) session=\(context.sessionID?.uuidString ?? "nil", privacy: .public) pane=\(context.paneID?.uuidString ?? "nil", privacy: .public) tab=\(context.tabID.uuidString, privacy: .public) process=\(context.processName ?? "nil", privacy: .public) pid=\(context.pid.map(String.init) ?? "nil", privacy: .public)")
        decide(allowed)
    }
    if case .osc52Read = kind {
        switch readPolicy {
        case .never:
            box.reason = .settingNever
            logged(false)
            return
        case .allow:
            box.reason = .settingAllow
            logged(true)
            return
        case .ask:
            break
        }
    }
    guard let session else {
        box.reason = .noSession
        logged(false)
        return
    }
    session.requestClipboardReadConfirmation(
        kind: kind,
        context: context,
        outcome: { box.reason = $0 },
        decide: logged
    )
}
