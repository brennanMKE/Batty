// SessionRuntime.swift

import Foundation
import GhosttyTerminal
import Observation

@Observable
public final class SessionRuntime: Identifiable {
    public let id: UUID
    public var title: String
    public let tree: SplitTree
    public internal(set) var unseenBellCount: Int = 0
    public var notificationsMuted: Bool = false
    /// `true` once the user has explicitly renamed the session via the
    /// sidebar rename action. Auto-derivation paths (project-name from
    /// CWD, name-cache lookups) check this and skip the rewrite — a
    /// user-set name pins permanently. See `#0089`.
    public var titleOverride: Bool = false
    /// Per-session theme override. When non-nil, switching to this session
    /// applies this theme instead of the global `ThemePreference`. Not
    /// persisted — resets to nil on every launch.
    public var localThemeName: String? = nil
    /// Whether the sidebar shows this session's pane rows. Collapsed by
    /// default; `WindowRuntime.hidePane` expands it so a just-hidden pane's
    /// restore control is always reachable (#0258). Not persisted.
    public var isPaneListExpanded: Bool = false
    /// Index into `SessionColor.allCases`. Assigned by `WindowRuntime`'s
    /// least-used round-robin at creation and stable for the Session's
    /// lifetime unless the user explicitly picks a color (#0336, via
    /// `WindowRuntime.setSessionColor(id:to:)`). A plain `Int`, not
    /// `SessionColor` itself, so a future persisted Session (`Concepts.md`:
    /// "Persisted: nothing" today) stores a trivially codable value.
    public var colorIndex: Int
    /// `true` once the user has explicitly chosen this Session's color via
    /// the Sidebar context menu's color picker, overriding the automatic
    /// assigner — the same precedent as `titleOverride` (#0089): a
    /// user-pinned value that auto-derivation paths must not rewrite.
    /// `WindowRuntime.resetSessionColor(id:)` clears this without touching
    /// `colorIndex`, so the Session keeps its current color and simply
    /// re-enters assigner control (#0336's Open questions: no immediate
    /// re-derivation on reset). Not persisted — resets to `false` on every
    /// launch, same as every other `SessionRuntime` UI-state field.
    public var colorOverride: Bool
    /// The Project this Session was opened from, if any. Informational and
    /// in-memory only: never persisted, and nothing writes it back to the
    /// Project.
    public internal(set) var projectID: UUID?
    @ObservationIgnored public let paneFrames: PaneFrameTracker

    /// Clipboard-read confirmation awaiting the user's answer, shown via
    /// `.confirmationDialog` in `SessionDetailView`. At most one at a time
    /// per Session: a second request arriving while one is already pending
    /// immediately denies the first (`decide(false)`, in
    /// `requestClipboardReadConfirmation(kind:decide:)`) rather than
    /// queuing it — nothing here waits silently for a confirmation that
    /// isn't the one on screen. `answerPendingClipboardConfirmation` and
    /// `cancelPendingClipboardConfirmation` take the specific
    /// `PendingClipboardConfirmation` the caller means to resolve and check
    /// its identity against whatever is *currently* pending, so a view
    /// closure holding a reference to an already-displaced or
    /// already-answered request safely no-ops instead of re-firing a
    /// decision or clobbering a newer request's bookkeeping (#0390 round 2,
    /// B2).
    public var pendingClipboardConfirmation: PendingClipboardConfirmation?

    /// This Session's remembered answers to a clipboard confirmation
    /// (unsafe paste, or a protected OSC 52 read/write) — one slot **per
    /// `TerminalClipboardRequestKind`**, not a single Session-wide flag.
    /// An Allow on a benign-sounding kind (e.g. a clipboard *write*
    /// prompt) must never silently authorize a more dangerous kind (e.g.
    /// an OSC 52 *read* / exfiltration path) just because both happened in
    /// the same Session (#0390 round 2, B1). `nil` per kind until the user
    /// answers a request of that kind once, then applied to later requests
    /// of that same kind without prompting again. **Not persisted**:
    /// resets on every relaunch and dies with the Session, matching every
    /// other per-Session UI-state field here (`Concepts.md`: Session
    /// "Persisted: nothing").
    ///
    /// `TerminalClipboardRequestKind` is `Sendable` but not `Hashable`, so
    /// this is three explicit slots rather than a dictionary keyed by it.
    @ObservationIgnored private var rememberedPasteDecision: Bool?
    @ObservationIgnored private var rememberedOSC52ReadDecision: Bool?
    @ObservationIgnored private var rememberedOSC52WriteDecision: Bool?

    private func rememberedDecision(for kind: TerminalClipboardRequestKind) -> Bool? {
        switch kind {
        case .paste: rememberedPasteDecision
        case .osc52Read: rememberedOSC52ReadDecision
        case .osc52Write: rememberedOSC52WriteDecision
        }
    }

    private func setRememberedDecision(_ allow: Bool, for kind: TerminalClipboardRequestKind) {
        switch kind {
        case .paste: rememberedPasteDecision = allow
        case .osc52Read: rememberedOSC52ReadDecision = allow
        case .osc52Write: rememberedOSC52WriteDecision = allow
        }
    }

    /// Test/diagnostic probe for the per-kind remembered policy above —
    /// there's no other way to observe it from outside this type.
    public func rememberedClipboardDecision(for kind: TerminalClipboardRequestKind) -> Bool? {
        rememberedDecision(for: kind)
    }

    /// Routes a clipboard confirmation from the terminal wrapper
    /// (`TerminalSurfaceClipboardConfirmationDelegate`) through this
    /// Session's remembered-answer policy. A request already pending when
    /// this is called is displaced and immediately denied — see
    /// `pendingClipboardConfirmation`'s doc comment.
    public func requestClipboardReadConfirmation(
        kind: TerminalClipboardRequestKind,
        decide: @escaping (Bool) -> Void
    ) {
        if let remembered = rememberedDecision(for: kind) {
            decide(remembered)
            return
        }
        pendingClipboardConfirmation?.decide(false)
        pendingClipboardConfirmation = PendingClipboardConfirmation(
            kind: kind,
            decide: decide
        )
    }

    /// The user answered the dialog for `request`. A no-op if `request`
    /// isn't the request currently pending (already displaced by a later
    /// request, or already resolved by a Session switch) — its decision
    /// already fired wherever that happened, and firing again here would
    /// double-answer it.
    public func answerPendingClipboardConfirmation(_ request: PendingClipboardConfirmation, allow: Bool) {
        guard pendingClipboardConfirmation?.id == request.id else { return }
        pendingClipboardConfirmation = nil
        setRememberedDecision(allow, for: request.kind)
        request.decide(allow)
    }

    /// The dialog for `request` was dismissed without an explicit answer
    /// (e.g. Escape, click-outside, or the user navigating away from this
    /// Session while it was up). Never a silent allow — deny, matching the
    /// policy that motivated the confirmation in the first place. Not
    /// remembered: a dismiss isn't the user expressing a Session-wide
    /// policy, just closing the prompt. Identity-checked the same way as
    /// `answerPendingClipboardConfirmation`.
    public func cancelPendingClipboardConfirmation(_ request: PendingClipboardConfirmation) {
        guard pendingClipboardConfirmation?.id == request.id else { return }
        pendingClipboardConfirmation = nil
        request.decide(false)
    }

    public init(
        id: UUID = UUID(),
        title: String = "Session",
        tree: SplitTree? = nil,
        unseenBellCount: Int = 0,
        notificationsMuted: Bool = false,
        titleOverride: Bool = false,
        colorIndex: Int = 0,
        colorOverride: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tree = tree ?? SplitTree()
        self.unseenBellCount = unseenBellCount
        self.notificationsMuted = notificationsMuted
        self.titleOverride = titleOverride
        self.colorIndex = colorIndex
        self.colorOverride = colorOverride
        self.paneFrames = PaneFrameTracker()
        // #0281: attach every pane/tab already in the tree (whether the
        // caller-supplied tree or the default single-pane one above) to
        // this session's id, so BATTY_SESSION_ID/BATTY_PANE_ID are set
        // before any surface in it can spawn.
        self.tree.attachToSession(self.id)
    }

    /// The focused Pane, regardless of `kind`. Named `AnyKind` (not
    /// `focusedPane`) so reaching for it reads as a deliberate opt-out of
    /// the kind check, not the path of least resistance (#0332) — safe for
    /// kind-agnostic uses (focus tracking, tree layout, "which pane is
    /// this" lookups) that never read `.tabs`/`.activeTab`. Anything that
    /// resolves a Tab to act on — add, close, rename, send text — must go
    /// through `focusedTerminalPane` (or `AppStateStore.focusedTerminalTab`
    /// for tab-scoped Terminal actions) instead: a non-terminal pane's one
    /// `TabRuntime` is a structural placeholder `PaneView` never renders
    /// (`PaneRuntime.kind`'s doc comment), and treating it like a real Tab
    /// container is the defect class `docs/pane-kinds.md`'s `#0315`
    /// implementation note catalogs at length.
    public var focusedPaneAnyKind: PaneRuntime {
        tree.focusedPane
    }

    /// The resolved palette color for `colorIndex`. Falls back to `.blue`
    /// for an out-of-range index rather than crashing — defensive only;
    /// every assignment path keeps `colorIndex` within `SessionColor`'s
    /// case count.
    public var sessionColor: SessionColor {
        SessionColor(rawValue: colorIndex) ?? .blue
    }

    /// `focusedPaneAnyKind`, but `nil` when it isn't a `.terminal`-kind
    /// pane.
    ///
    /// Every Tab-scoped command (Cmd-T, Cmd-W, tab-switching, Exit Shell —
    /// whether dispatched from the menu bar, the global keyboard-shortcut
    /// monitor, or the Command Palette) must resolve its target pane
    /// through this, not `focusedPaneAnyKind` directly: a non-terminal
    /// pane's one `TabRuntime` is a structural placeholder `PaneView` never
    /// renders (`PaneRuntime.kind`'s doc comment), and mutating it (adding
    /// a second invisible tab, closing the only one) is a real bug, not a
    /// cosmetic one — see `docs/pane-kinds.md`'s `#0315` implementation
    /// note for the three independent dispatch paths this was found
    /// reachable from in review (#0315 review rounds 1 and 2, finding 2).
    public var focusedTerminalPane: PaneRuntime? {
        let pane = focusedPaneAnyKind
        return pane.kind == .terminal ? pane : nil
    }
}
