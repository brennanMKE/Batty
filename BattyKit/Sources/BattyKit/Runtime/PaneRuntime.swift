// PaneRuntime.swift

import Foundation
import Observation

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

    public init(
        id: UUID = UUID(),
        tabs: [TabRuntime]? = nil,
        unseenBellCount: Int = 0,
        isHidden: Bool = false,
        kind: PaneContentKind = .terminal
    ) {
        self.id = id
        let initial = tabs ?? [TabRuntime()]
        precondition(!initial.isEmpty, "PaneRuntime must contain at least one Tab")
        self.tabs = initial
        self.activeTabID = initial[0].id
        self.unseenBellCount = unseenBellCount
        self.isHidden = isHidden
        self.kind = kind
    }

    /// A `Pane` value-type snapshot suitable for workspace persistence.
    public func snapshot() -> Pane {
        Pane(id: id, isHidden: isHidden, kind: kind)
    }

    public var activeTab: TabRuntime? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    @discardableResult
    public func addTab(inheritingCWDFrom source: TabRuntime? = nil) -> TabRuntime {
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

    public func closeActiveTab() {
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
