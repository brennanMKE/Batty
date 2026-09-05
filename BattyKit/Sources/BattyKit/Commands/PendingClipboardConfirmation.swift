// PendingClipboardConfirmation.swift

import Foundation
import GhosttyTerminal

/// Captured when a terminal program needs the user's explicit permission for
/// a clipboard operation — an unsafe paste, or a protected OSC 52 read/write
/// — because that's an exfiltration/injection vector libghostty requires an
/// answer for rather than defaulting to allow. The view layer presents the
/// dialog; the owning `SessionRuntime` answers it via `decide`, which
/// resolves the wrapper's request exactly once
/// (`TerminalSurfaceClipboardConfirmationDelegate`'s contract).
///
/// Upstream's `TerminalClipboardConfirmationRequest` does not surface a
/// requesting-program name or a per-request "can this be remembered" flag
/// (see `TerminalDelegateProxy.onClipboardReadConfirmationRequest`), so
/// this only carries `kind` — enough to phrase the prompt, not to name the
/// program.
public struct PendingClipboardConfirmation: Identifiable {
    public let id = UUID()
    let kind: TerminalClipboardRequestKind
    let decide: (Bool) -> Void

    public var title: String {
        String(localized: "Allow Clipboard Access?")
    }

    public var message: String {
        switch kind {
        case .paste:
            return String(localized: "A terminal program wants to paste clipboard contents that may be unsafe.")
        case .osc52Read:
            return String(localized: "A terminal program wants to read the clipboard.")
        case .osc52Write:
            return String(localized: "A terminal program wants to write to the clipboard.")
        }
    }
}

/// The other fail-open leg PaneView must never get wrong: a clipboard-read
/// confirmation whose owning Session cannot be resolved (e.g. the tab's
/// Session hasn't been attached yet, or the tab closed before the wiring in
/// `PaneView` ran) must deny, never leave the request unanswered and never
/// default to allow. Pulled out to a free function, rather than left inline
/// in the `PaneView` closure body, so it has direct test coverage that
/// doesn't need a live `AppStateStore`/`TabRuntime`.
func routeClipboardReadConfirmation(
    to session: SessionRuntime?,
    kind: TerminalClipboardRequestKind,
    decide: @escaping (Bool) -> Void
) {
    guard let session else {
        decide(false)
        return
    }
    session.requestClipboardReadConfirmation(kind: kind, decide: decide)
}
