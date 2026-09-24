// PaneRuntime.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PaneRuntime")

@Observable
public final class PaneRuntime: Identifiable {
    public let id: UUID
    public var tabs: [TabRuntime]
    public var activeTabID: UUID
    public internal(set) var unseenBellCount: Int = 0
    /// Whether this pane is hidden from view. The Ghostty surface (PTY +
    /// scrollback) keeps running; only the placement in `TerminalHostStore`
    /// is zeroed. Tree structure is unchanged — hidden is a leaf property.
    public var isHidden: Bool = false

    /// The owning session, set by ``attachToSession(_:)`` once this pane
    /// joins a `SessionRuntime`'s `SplitTree`. `nil` for a pane not yet
    /// attached (see `TabRuntime.attachContext(paneID:sessionID:)` for why
    /// this is deferred rather than known at `init`).
    public internal(set) var sessionID: UUID?

    /// The kind of content this pane hosts (`docs/pane-kinds.md`). Set once
    /// at `init` and never mutated — there is no user-facing "convert this
    /// pane" operation. `.terminal` is the default so every existing call
    /// site (there are many, across `SplitTree`, `SessionRuntime.init`,
    /// tests) keeps constructing an ordinary terminal pane unchanged.
    ///
    /// Scope note (#0315): a non-terminal-kind `PaneRuntime` still holds one
    /// ordinary `TabRuntime`, exactly like a terminal pane — `tabs` does not
    /// become `[]` and `activeTabID` does not become optional, which is a
    /// deliberate narrowing of `docs/pane-kinds.md` §1's fuller design (that
    /// document itself calls the `tabs: []`/`activeTabID: UUID?` migration
    /// "real, mechanical churn across a double-digit number of call sites"
    /// and explicitly punts performing it to whichever issue wires the
    /// model in). `PaneView`'s non-terminal arm never reads or renders that
    /// tab — it never reaches `TerminalPlaceholderView`, so no PTY is ever
    /// spawned — so the only cost is one otherwise-inert `TerminalViewState`
    /// per non-terminal pane. This keeps the change surgical: every
    /// existing reader of `pane.tabs`/`pane.activeTabID` (there are
    /// double digits of them too — `WindowRuntime`, `AppStateStore`,
    /// `TopologyPayloadBuilder`, the sidebar pane row) keeps compiling and
    /// behaving unchanged, and the close cascade
    /// (`WindowRuntime.closePane`) tears the inert tab down through its
    /// existing, unmodified path with no kind-gated branch needed. Flagging
    /// for whoever implements the first real non-terminal view (most likely
    /// #0304): if that view needs the full `tabs: []` migration for its own
    /// reasons, it still has to happen then; it was not required to land
    /// the CLI plumbing this issue ships.
    public let kind: PaneContentKind

    /// Model-owned non-terminal content, addressable by the pane's owner
    /// (`WindowRuntime.hidePane`/`showPane`/`closePane`) without depending
    /// on SwiftUI view identity — the same relationship
    /// `TabRuntime.terminal: TerminalViewState` has to its Tab
    /// (`docs/pane-view-lifecycle.md` §5, "the conformer is model-owned").
    /// `nil` for `.terminal` panes and for any non-terminal kind that
    /// hasn't wired a concrete conformer yet — `.systemMetrics` (#0314) and
    /// `.gitStatus` (#0304) are the only kinds with one today. Set once at
    /// `init`, alongside `kind`, and never mutated.
    public let content: (any PaneContentLifecycle)?

    /// Builds the concrete `PaneContentLifecycle` conformer for `kind`, or
    /// `nil` for kinds with no conformer (yet). The default
    /// `contentFactory` `PaneRuntime.init` uses.
    ///
    /// A `.gitStatus` pane built through this default resolves its
    /// directory to `$HOME` — the resolution-order fallback of last resort
    /// (`docs/design/git-status-view.md` §1). A caller that has a better
    /// answer (the CLI's `--path`, or the source pane's cwd when splitting)
    /// passes its own `contentFactory` to `PaneRuntime.init` instead of
    /// relying on this default — see `SplitTree.makePane`.
    ///
    /// **Exhaustive, no `default:`** — adding a new `PaneContentKind` case
    /// without adding a matching arm here is a compile error, not a
    /// silently-resolved-to-`nil` gap. `#0305`/`#0313` land their own arms
    /// as each conformer ships; today they still resolve to `nil`
    /// explicitly, matched case-by-case, not through a catch-all that
    /// would also swallow a real future omission.
    public static func makeContent(for kind: PaneContentKind) -> (any PaneContentLifecycle)? {
        switch kind {
        case .terminal: return nil
        case .gitStatus: return GitStatusPaneContent(directoryPath: NSHomeDirectory())
        case .processStatus: return nil
        case .lmStudioDashboard: return LMStudioDashboardPaneContent()
        case .systemMetrics: return SystemMetricsPaneContent()
        }
    }

    public init(
        id: UUID = UUID(),
        tabs: [TabRuntime]? = nil,
        unseenBellCount: Int = 0,
        isHidden: Bool = false,
        kind: PaneContentKind = .terminal,
        isSessionSelected: Bool = true,
        contentFactory: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)? = PaneRuntime.makeContent
    ) {
        self.id = id
        let initial = tabs ?? [TabRuntime()]
        precondition(!initial.isEmpty, "PaneRuntime must contain at least one Tab")
        self.tabs = initial
        self.activeTabID = initial[0].id
        self.unseenBellCount = unseenBellCount
        self.isHidden = isHidden
        // `contentFactory` is injectable specifically so test code that
        // constructs a `.systemMetrics` (or future non-terminal-kind)
        // `PaneRuntime` isn't forced to also start a real conformer's real
        // background work (a live 1 Hz sampling `Task` making real host/
        // IOKit calls, in this kind's case) as a side effect of
        // construction — `docs/pane-view-lifecycle.md` §5 still requires
        // `setUp` to run "at Pane creation," not from view-driven code; the
        // factory changes *who builds the conformer*, not *when `setUp`
        // runs*. Production call sites all use the default, unchanged
        // behavior (`PaneRuntime.makeContent`).
        let content = contentFactory(kind)
        self.content = content
        // The non-selected-Session visibility fact is delivered post-
        // construction by `WindowRuntime.selectedSessionID`'s `didSet` →
        // `applySelectionVisibility` (#0349) for every *later* selection
        // change, but a Pane can be *created* directly into a background
        // (non-selected) Session — `AppStateStore.splitPane(id:...)`'s XPC
        // `pane split` verb never touches `selectedSessionID` (#0257: a
        // mutation aimed at a background target must not switch the active
        // session), so construction time is the one moment that sweep can't
        // reach. `isSessionSelected` is how the caller supplies that fact
        // up front, so a Pane created hidden *or* created into a background
        // Session goes straight to `.suspended` without ever passing through
        // `.active` — `docs/pane-view-lifecycle.md` §3's `notSetUp →
        // suspended` edge. Defaults to `true` here — unlike
        // `SplitTree.makePane`'s own `isSessionSelected` parameter, which
        // has no default (`#0359` applied the same rule to that function's
        // `tabLookup`) — because every production non-terminal Pane goes
        // through `makePane`, which already requires the flag; this
        // default only covers direct `PaneRuntime(kind:...)` construction,
        // overwhelmingly test code with no notion of "which Session is
        // selected" to supply.
        content?.setUp(visible: !isHidden && isSessionSelected)
        self.kind = kind
    }

    /// A `Pane` value-type snapshot suitable for workspace persistence.
    public func snapshot() -> Pane {
        Pane(id: id, isHidden: isHidden, kind: kind)
    }

    public var activeTab: TabRuntime? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    /// Adds a new Tab to this Pane. **Gated on `kind == .terminal`** (#0332)
    /// — a non-terminal pane's one `TabRuntime` is a structural placeholder
    /// `PaneView` never renders (`kind`'s doc comment above); adding a
    /// second one would produce an invisible orphan tab no view can reach,
    /// the exact defect class `docs/pane-kinds.md`'s `#0315` implementation
    /// note catalogs. Gating here, at the mutation itself, means the
    /// invariant holds regardless of which accessor spelling a caller used
    /// to reach this pane — `SessionRuntime.focusedPaneAnyKind`'s rename
    /// only helps callers that go through it; this does not require that.
    /// Returns the existing active tab and logs rather than trapping: this
    /// guards a call-site bug, not a fatal invariant, and the caller is
    /// often shared UI dispatch code where a crash is worse than a no-op.
    @discardableResult
    public func addTab(inheritingCWDFrom source: TabRuntime? = nil) -> TabRuntime {
        guard kind == .terminal else {
            let kindName = kind.rawValue
            logger.error("addTab called on a non-terminal pane (kind=\(kindName, privacy: .public)); ignoring")
            return activeTab ?? tabs[0]
        }
        let cwd = source?.terminal.workingDirectory
        let tab = TabRuntime(workingDirectory: cwd)
        tabs.append(tab)
        activeTabID = tab.id
        if let sessionID {
            tab.attachContext(paneID: id, sessionID: sessionID)
        }
        return tab
    }

    /// Attaches this pane (and every tab it currently holds) to `sessionID`.
    /// Called by `SplitTree.attachToSession(_:)` for the tree's existing
    /// panes and by `SplitTree.splitFocusedPane`/`splitFullDimension` for a
    /// freshly-created pane — both always run before this pane's tabs can
    /// have a live libghostty surface (see `TabRuntime.attachContext`).
    public func attachToSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        for tab in tabs {
            tab.attachContext(paneID: id, sessionID: sessionID)
        }
    }

    /// Removes a tab by id. Allows the pane to become empty — callers
    /// must handle the empty case (typically by removing the pane).
    /// Use ``AppStateStore/closeTab(id:)`` for the full cascade.
    ///
    /// Also releases the tab's `AppTerminalView` from the
    /// ``TerminalHostStore``. This is the one place in the app where the
    /// long-lived terminal view is removed from the host — `closeTab` is
    /// the only legitimate trigger for tearing down a libghostty surface
    /// (which kills the PTY).
    public func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if !tabs.isEmpty, activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
        TerminalHostStore.shared.releaseTerminalView(forTabID: id)
    }

    /// Closes this pane's active Tab. **Gated on `kind == .terminal`**
    /// (#0332), for the same reason as `addTab(inheritingCWDFrom:)` above —
    /// a non-terminal pane's one Tab is the structural placeholder that
    /// keeps the pane's active-tab bookkeeping well-formed; removing it
    /// would leave the pane with zero tabs, which `removeTab(id:)`'s own
    /// doc comment says callers must handle by removing the pane instead
    /// (`WindowRuntime.closeFocusedTab()`/`closePane` do that, and don't
    /// call this method — they call `closeNonTerminalPane` for a
    /// non-terminal focused pane). No production call site reaches this
    /// today, but it is public API, and the whole point of this gate is
    /// that the next caller does not have to already know that.
    public func closeActiveTab() {
        guard kind == .terminal else {
            let kindName = kind.rawValue
            logger.error("closeActiveTab called on a non-terminal pane (kind=\(kindName, privacy: .public)); ignoring")
            return
        }
        removeTab(id: activeTabID)
    }

    /// Removes every tab in the pane except the one with `id`. Used by the
    /// chip context menu's "Close Other Tabs". The kept tab becomes active.
    public func closeOtherTabs(keeping id: UUID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        let removedIDs = tabs.filter { $0.id != id }.map(\.id)
        tabs = [kept]
        activeTabID = kept.id
        for removedID in removedIDs {
            TerminalHostStore.shared.releaseTerminalView(forTabID: removedID)
        }
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    public func selectNextTab() {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let next = (current + 1) % tabs.count
        activeTabID = tabs[next].id
    }

    public func selectPreviousTab() {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return }
        let prev = (current - 1 + tabs.count) % tabs.count
        activeTabID = tabs[prev].id
    }
}
