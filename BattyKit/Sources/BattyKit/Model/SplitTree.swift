// SplitTree.swift

import Foundation
import Observation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SplitTree")

// Used internally by rebalancingChain to signal whether paneID was found reachable
// through a contiguous same-direction chain from the current node.
private enum ChainSearchResult {
    case notFound
    // paneID is in this subtree, reachable through a D-direction chain from this node.
    case foundInDChain(SplitTreeNode)
    // paneID is in this subtree, but the path crossed a perpendicular split.
    case foundBelowBreak(SplitTreeNode)

    var updatedNode: SplitTreeNode? {
        switch self {
        case .notFound: return nil
        case .foundInDChain(let n): return n
        case .foundBelowBreak(let n): return n
        }
    }
}

public indirect enum SplitTreeNode {
    case leaf(PaneRuntime)
    case split(id: UUID, direction: SplitDirection, ratio: Double, left: SplitTreeNode, right: SplitTreeNode)
}

extension SplitTreeNode {
    public var firstLeafPaneID: UUID {
        switch self {
        case .leaf(let pane):
            return pane.id
        case .split(_, _, _, let left, _):
            return left.firstLeafPaneID
        }
    }

    public var firstLeafPane: PaneRuntime {
        switch self {
        case .leaf(let pane):
            return pane
        case .split(_, _, _, let left, _):
            return left.firstLeafPane
        }
    }

    public func findPane(id: UUID) -> PaneRuntime? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, _, _, let left, let right):
            return left.findPane(id: id) ?? right.findPane(id: id)
        }
    }

    public var allLeafPanes: [PaneRuntime] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(_, _, _, let left, let right):
            return left.allLeafPanes + right.allLeafPanes
        }
    }

    /// All leaf panes in this subtree whose `isHidden` is `false`.
    public var visibleLeafPanes: [PaneRuntime] {
        switch self {
        case .leaf(let pane):
            return pane.isHidden ? [] : [pane]
        case .split(_, _, _, let left, let right):
            return left.visibleLeafPanes + right.visibleLeafPanes
        }
    }

    /// `true` when every leaf pane in this subtree is hidden.
    /// Used by `SplitNodeView` to collapse layout space for fully-hidden
    /// sub-trees and to suppress dividers adjacent to them.
    public var isEntirelyHidden: Bool {
        switch self {
        case .leaf(let pane):
            return pane.isHidden
        case .split(_, _, _, let left, let right):
            return left.isEntirelyHidden && right.isEntirelyHidden
        }
    }

    public func contains(paneID: UUID) -> Bool {
        findPane(id: paneID) != nil
    }

    /// First (leftmost/topmost) leaf pane id in this subtree that is not
    /// hidden, or `nil` when every leaf is hidden. Used by
    /// `SplitTree.removePane`'s successor fallback chain (#0337) so a
    /// positional fallback never blindly lands on a hidden pane the way the
    /// pre-#0337 `firstLeafPaneID` fallback did.
    var firstVisibleLeafPaneID: UUID? {
        switch self {
        case .leaf(let pane):
            return pane.isHidden ? nil : pane.id
        case .split(_, _, _, let left, let right):
            return left.firstVisibleLeafPaneID ?? right.firstVisibleLeafPaneID
        }
    }

    /// The other child of the split whose *direct* leaf child is `id` — the
    /// subtree that absorbs `id`'s space when it is removed
    /// (`SplitTreeNode.removingPane`'s `(nil, r?) -> r` / `(l?, nil) -> l`
    /// cases). The recursion descends to any depth to find `id`'s actual
    /// immediate parent split, so `nil` means only "`id` is not present in
    /// this subtree at all" — never "found, but too deep." Must be computed
    /// against the tree as it existed *before* removal — the sibling
    /// relationship is structural and unaffected by the pane's own removal,
    /// but is only discoverable while both leaves are still present.
    static func siblingSubtree(of id: UUID, in node: SplitTreeNode) -> SplitTreeNode? {
        guard case .split(_, _, _, let left, let right) = node else { return nil }
        if case .leaf(let pane) = left, pane.id == id { return right }
        if case .leaf(let pane) = right, pane.id == id { return left }
        return siblingSubtree(of: id, in: left) ?? siblingSubtree(of: id, in: right)
    }
}

@Observable
public final class SplitTree {
    public var root: SplitTreeNode
    /// Most-recent-first history of every pane this tree has deliberately
    /// focused (#0337). `@ObservationIgnored` — bookkeeping no view should
    /// re-render on, same precedent as `SessionRuntime.paneFrames`.
    /// Populated entirely by `focusedPaneID`'s `didSet` below, which is the
    /// single choke point every write to `focusedPaneID` passes through
    /// (splits, clicks, XPC focus verbs, layout application, adjacent-pane
    /// movement) — no call site needs to remember to push explicitly, so
    /// none can silently degrade the stack to stale entries the way a
    /// call-site-by-call-site audit could. `private(set)` (rather than
    /// fully `private`) only so `@testable` unit tests can assert it stays
    /// bounded — still opaque to every non-test, non-file caller.
    ///
    /// **Bounding:** the dedupe in `didSet` (`removeAll { $0 ==
    /// focusedPaneID }` before inserting) is what keeps this array from
    /// growing without limit — alternating focus between the same two
    /// panes writes the same two ids over and over, and without the dedupe
    /// each write would append a fresh duplicate forever (the issue's fix
    /// sketch item 3 required the stack not grow unboundedly). Combined
    /// with `removePane`'s own pruning, this array's length can never
    /// exceed the tree's current live pane count.
    @ObservationIgnored private(set) var focusHistory: [UUID] = []

    public var focusedPaneID: UUID {
        didSet {
            guard focusedPaneID != oldValue else { return }
            focusHistory.removeAll { $0 == focusedPaneID }
            focusHistory.insert(focusedPaneID, at: 0)
        }
    }

    /// The owning session, set once by `SessionRuntime.init` via
    /// ``attachToSession(_:)``. Every pane created afterward through
    /// ``splitFocusedPane(direction:ratio:inheritingFrom:)`` or
    /// ``splitFullDimension(direction:ratio:inheritingFrom:)`` is attached
    /// to it immediately (#0281's `BATTY_PANE_ID`/`BATTY_SESSION_ID`
    /// plumbing). `nil` for a standalone tree not owned by any session
    /// (e.g. a bare unit-test fixture).
    public internal(set) var sessionID: UUID?

    public init(root: SplitTreeNode) {
        self.root = root
        // `didSet` never fires for a property's own initializer assignment,
        // so this does not seed `focusHistory` — it starts empty (its own
        // declared default) and the first *deliberate* focus change after
        // construction is the first real entry, matching `paneFrames`'s own
        // "starts empty" shape.
        self.focusedPaneID = root.firstLeafPaneID
    }

    public convenience init() {
        self.init(root: .leaf(PaneRuntime()))
    }

    /// Builds a tree whose only Pane is created with `kind`, `tabs` and
    /// `path` up front, through the same per-kind resolution `splitPane`
    /// uses (`makePane`), so a non-terminal first Pane is never a mutated
    /// Terminal Pane. A `.processStatus` first Pane has no split source, so
    /// it starts on the "No process selected" empty state.
    static func withFirstPane(
        kind: PaneContentKind,
        path: String? = nil,
        tabs: [TabRuntime]? = nil,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil,
        isSessionSelected: Bool
    ) -> SplitTree {
        final class Box { weak var tree: SplitTree? }
        let box = Box()
        let pane = makePane(
            inheritingFrom: nil,
            in: nil,
            kind: kind,
            path: path,
            tabs: tabs,
            contentFactory: contentFactory,
            isSessionSelected: isSessionSelected,
            tabLookup: { tabID in box.tree?.allPanes.flatMap(\.tabs).first(where: { $0.id == tabID }) }
        )
        let tree = SplitTree(root: .leaf(pane))
        box.tree = tree
        return tree
    }

    /// Attaches this tree and every pane it currently contains to
    /// `sessionID`. Called once by `SessionRuntime.init`.
    public func attachToSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        for pane in allPanes {
            pane.attachToSession(sessionID)
        }
    }

    public var focusedPane: PaneRuntime {
        root.findPane(id: focusedPaneID) ?? root.firstLeafPane
    }

    public var allPanes: [PaneRuntime] {
        root.allLeafPanes
    }

    /// All panes in the tree whose `isHidden` is `false`.
    public var visiblePanes: [PaneRuntime] {
        root.visibleLeafPanes
    }

    /// Splits the focused pane, adding a new pane along `direction`.
    ///
    /// After insertion, every leaf in the contiguous same-direction chain that
    /// contains the new pane is re-equalized to an even 1/n fraction (#0255).
    /// Because of that, `ratio` no longer affects the final geometry of a
    /// same-axis split — it is retained for API compatibility but overridden by
    /// the equalization pass. A perpendicular split starts a fresh 50/50 axis.
    @discardableResult
    public func splitFocusedPane(
        direction: SplitDirection,
        ratio: Double = 0.5,
        inheritingFrom source: PaneRuntime? = nil
    ) -> PaneRuntime {
        let newPane = Self.makePane(inheritingFrom: source, in: self, isSessionSelected: true, tabLookup: Self.tabLookup(for: self))
        if let sessionID {
            newPane.attachToSession(sessionID)
        }
        if let newRoot = SplitTreeNode.inserting(
            newPane: newPane,
            adjacentTo: focusedPaneID,
            direction: direction,
            ratio: ratio,
            into: root
        ) {
            // Rebalance the contiguous same-direction chain containing newPane so
            // all leaves in that chain have equal fractions (1/n).
            let result = SplitTreeNode.rebalancingChain(
                containing: newPane.id,
                direction: direction,
                in: newRoot,
                parentIsDSplit: false
            )
            root = result.updatedNode ?? newRoot
            focusedPaneID = newPane.id
        }
        return newPane
    }

    /// Wraps the whole tree in a new top-level split, adding a pane that
    /// spans the Session's full width (`.vertical` — new bottom row) or
    /// full height (`.horizontal` — new trailing column), instead of
    /// splitting only within the focused pane's bounds like
    /// `splitFocusedPane` does (#0262). The existing tree becomes the
    /// left/top child unchanged — no leaf pane is touched, so every
    /// existing Terminal Session survives the restructuring — and the new
    /// pane is the right/bottom child, matching `inserting(...)`'s
    /// convention of placing a new pane after the one it splits from.
    ///
    /// Unlike `splitFocusedPane`, this never chain-rebalances: it is a
    /// single wrap of whatever the tree currently is, so the new pane
    /// simply takes an even half (`ratio` default 0.5) of the outermost
    /// dimension regardless of how many panes already exist.
    @discardableResult
    public func splitFullDimension(
        direction: SplitDirection,
        ratio: Double = 0.5,
        inheritingFrom source: PaneRuntime? = nil
    ) -> PaneRuntime {
        let newPane = Self.makePane(inheritingFrom: source, in: self, isSessionSelected: true, tabLookup: Self.tabLookup(for: self))
        if let sessionID {
            newPane.attachToSession(sessionID)
        }
        root = .split(id: UUID(), direction: direction, ratio: ratio, left: root, right: .leaf(newPane))
        focusedPaneID = newPane.id
        return newPane
    }

    /// The real by-id Tab lookup a `.processStatus` pane's
    /// `ProcessStatusPaneContent` holds for its whole life, regardless of
    /// its current target — a `.pinned`/`nil` target simply never calls
    /// it. `[weak tree]` because that held closure must not keep the tree
    /// (or, transitively, every Pane/Tab it reaches) alive past the
    /// tree's own lifetime.
    private static func tabLookup(for tree: SplitTree) -> (UUID) -> TabRuntime? {
        { [weak tree] tabID in
            tree?.allPanes.flatMap(\.tabs).first(where: { $0.id == tabID })
        }
    }

    /// `kind != .terminal` skips `command` entirely — it presumes a shell.
    /// The directory a new Pane inherits comes from ``inheritedSource(from:in:tabLookup:)``
    /// for every `kind` and every source kind, terminal or not.
    /// `splitFocusedPane`/`splitFullDimension` build terminal Panes only;
    /// `splitPane(id:...)` and `withFirstPane(kind:...)` are the callers that can
    /// pass a non-terminal `kind` (#0315's XPC `pane split --view <kind>`,
    /// `WindowRuntime.createPane`, and a Project whose first slot is Git Status
    /// or Process Status). `withFirstPane` passes no source and no tree, so
    /// nothing is inherited.
    /// `contentFactory` forwards to `PaneRuntime.init`'s own injection
    /// point (#0313 review round 1) — `nil` (the default) means "resolve
    /// automatically," per kind: `PaneRuntime.makeContent` for every kind
    /// except `.processStatus` and `.gitStatus`, each of which needs
    /// call-site context (`processStatusPid`/the tree's tab-lookup
    /// closure; `path`/`source`'s cwd) that `makeContent(for:)`'s
    /// `kind`-only signature can't carry, so both are resolved here
    /// instead. A caller that explicitly supplies its own `contentFactory`
    /// — test code that needs a non-terminal-kind pane without triggering
    /// its real conformer's `setUp()` (a real subprocess/HTTP poll for
    /// `.lmStudioDashboard`, a real sampling `Task` for `.systemMetrics`,
    /// a real `FSEventStream`/subprocess for `.gitStatus`, or `.processStatus`'s
    /// own polling) — always wins outright, regardless of kind:
    /// `contentFactory: { _ in nil }` must suppress real construction even
    /// for a kind with call-site-specific resolution below, not be
    /// silently overridden by it. This is why the parameter is `Optional`
    /// with a `nil` default rather than defaulting directly to
    /// `PaneRuntime.makeContent` the way `PaneRuntime.init`'s own
    /// parameter still does — a concrete closure default can't be
    /// distinguished from an explicitly-passed one, so there would be no
    /// way to tell "caller wants the automatic per-kind behavior" apart
    /// from "caller wants exactly `PaneRuntime.makeContent`, verbatim." The
    /// order matters: the `if let contentFactory` check must run *first*,
    /// unconditionally, before any kind-specific branch — putting a
    /// kind-specific branch first would silently ignore an explicit
    /// override for that one kind, exactly the trap `#0304`'s own rebase
    /// onto this parameter hit and had to fix.
    ///
    /// `path`, added by #0304, is the directory a `.gitStatus` pane
    /// monitors when this function's own default applies — resolved per
    /// `docs/design/git-status-view.md` §1's order: explicit CLI `--path`,
    /// else the directory ``inheritedSource(from:in:tabLookup:)`` resolves
    /// from `source` (the same cwd a terminal split would inherit), else
    /// `$HOME`. Ignored for `.terminal`, and ignored (not just unused —
    /// never read) whenever an explicit `contentFactory` is supplied.
    ///
    /// `tabs`, when non-empty, are the Tabs a new `.terminal` pane is built
    /// with instead of the single cwd-inheriting one; ignored for every
    /// other kind. They take precedence over `command` and cwd inheritance.
    ///
    /// `tabLookup` is required (no default): a `.processStatus` pane's
    /// `.followingTab` targets — including ones picked later via
    /// retarget — resolve only through it, so every caller, terminal-kind
    /// splits included, must supply a real by-id lookup even though it is only
    /// invoked by the `.processStatus` branch below and by
    /// `inheritedSource(from:in:tabLookup:)` to resolve a Process Status
    /// source's followed Tab.
    private static func makePane(
        inheritingFrom source: PaneRuntime?,
        in tree: SplitTree?,
        command: String? = nil,
        kind: PaneContentKind = .terminal,
        processStatusPid: Int32? = nil,
        path: String? = nil,
        tabs: [TabRuntime]? = nil,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil,
        isSessionSelected: Bool,
        tabLookup: @escaping (UUID) -> TabRuntime?
    ) -> PaneRuntime {
        if kind == .terminal, let tabs, !tabs.isEmpty {
            return PaneRuntime(tabs: tabs)
        }
        let inherited = inheritedSource(from: source, in: tree, tabLookup: tabLookup)
        guard kind == .terminal else {
            let resolvedFactory: @MainActor (PaneContentKind) -> (any PaneContentLifecycle)?
            if let contentFactory {
                resolvedFactory = contentFactory
            } else if kind == .processStatus {
                // #0305 mode selection: an explicit `--pid` pins mode A;
                // otherwise mode B follows `inherited.followedTabID` (see
                // `inheritedSource`): the terminal source's active Tab, else
                // the Process Status source's followed Tab, else the most
                // recently focused terminal Pane's active Tab. It is nil
                // (the "No process selected" empty state) with no source or
                // no terminal Pane to follow.
                let target: ProcessStatusPaneContent.Target? = processStatusPid.map { .pinned($0) }
                    ?? inherited.processTarget
                    ?? inherited.followedTabID.map { .followingTab($0) }
                resolvedFactory = { _ in ProcessStatusPaneContent(target: target, tabLookup: tabLookup) }
            } else if kind == .gitStatus {
                // #0304's own directory resolution — see this function's
                // doc comment above for why this branch comes *after* the
                // `if let contentFactory` check, never before it.
                let resolvedPath = path ?? inherited.workingDirectory ?? NSHomeDirectory()
                resolvedFactory = { _ in GitStatusPaneContent(directoryPath: resolvedPath) }
            } else {
                resolvedFactory = PaneRuntime.makeContent
            }
            return PaneRuntime(kind: kind, isSessionSelected: isSessionSelected, contentFactory: resolvedFactory)
        }
        guard source != nil else {
            return command == nil ? PaneRuntime() : PaneRuntime(tabs: [TabRuntime(command: command)])
        }
        return PaneRuntime(tabs: [TabRuntime(workingDirectory: inherited.workingDirectory, command: command)])
    }

    struct InheritedSource: Equatable {
        enum Step: String {
            case none
            case terminal
            case gitStatusDirectory
            case followedTab
            case recentTerminal
        }

        var workingDirectory: String?
        var followedTabID: UUID?
        var processTarget: ProcessStatusPaneContent.Target?
        var step: Step
    }

    /// The single owner of "what does a Pane split from `source` inherit".
    /// Precedence, per directory: a terminal source's active Tab; a Git Status
    /// source's `directoryPath` (not its repository toplevel, so a subdirectory
    /// stays a subdirectory); a Process Status source following a Tab that
    /// still resolves, that Tab's directory; otherwise the most recently
    /// focused terminal Pane in `tree`, else the first terminal Pane in
    /// depth-first order (`focusHistory` is not seeded at construction), else
    /// nothing. Hidden Panes count. A non-terminal Pane's own placeholder Tab
    /// never has a directory and is never followed. A followed Process Status Tab
    /// with no cwd is still followed by a new Process Status Pane, while a
    /// terminal split falls through to the most recent terminal for its
    /// directory; this is deliberate, so the new Pane keeps watching the same
    /// process. A Process Status source that is pinned or following a name
    /// has no Tab to follow, so its `Target` is carried in `processTarget` for
    /// a Process Status destination, while the directory still falls through
    /// to the most recently focused terminal Pane.
    ///
    /// `tree` is nil only for a Pane built before its tree exists
    /// (`withFirstPane`), which has no `source` either, so the result is
    /// `.none`.
    ///
    /// Reads `terminal.workingDirectory` (the live value), not the
    /// `TabRuntime.workingDirectory` mirror: this runs once from an
    /// event-driven split, the case the mirror's doc comment lists for the raw
    /// property.
    static func inheritedSource(
        from source: PaneRuntime?,
        in tree: SplitTree?,
        tabLookup: (UUID) -> TabRuntime?
    ) -> InheritedSource {
        guard let source else { return InheritedSource(workingDirectory: nil, followedTabID: nil, processTarget: nil, step: .none) }

        func directory(of tab: TabRuntime) -> String? {
            tab.terminal.workingDirectory ?? tab.terminal.configuration.workingDirectory
        }

        let result: InheritedSource
        switch source.kind {
        case .terminal:
            result = InheritedSource(
                workingDirectory: source.activeTab.flatMap(directory(of:)),
                followedTabID: source.activeTabID,
                processTarget: nil,
                step: .terminal
            )
        default:
            var directoryPath: String?
            var step = InheritedSource.Step.none
            var followedTabID: UUID?
            var processTarget: ProcessStatusPaneContent.Target?
            if let git = source.content as? GitStatusPaneContent {
                directoryPath = git.directoryPath
                step = .gitStatusDirectory
            } else if let process = source.content as? ProcessStatusPaneContent {
                switch process.target {
                case .pinned, .followingName:
                    processTarget = process.target
                case .followingTab(let id):
                    if let tab = tabLookup(id) {
                        followedTabID = tab.id
                        if let cwd = directory(of: tab) {
                            directoryPath = cwd
                            step = .followedTab
                        }
                    }
                case nil:
                    break
                }
            }
            let fallbackTab = tree.flatMap(mostRecentTerminalPane(in:))?.activeTab
            if directoryPath == nil {
                directoryPath = fallbackTab.flatMap(directory(of:))
                step = directoryPath == nil ? .none : .recentTerminal
            }
            result = InheritedSource(
                workingDirectory: directoryPath,
                followedTabID: followedTabID ?? fallbackTab?.id,
                processTarget: processTarget,
                step: step
            )
        }
        logger.info("split-tree: inherited cwd step=\(result.step.rawValue, privacy: .public) source-kind=\(source.kind.rawValue, privacy: .public) resolved=\(result.workingDirectory ?? "nil", privacy: .private)")
        return result
    }

    private static func mostRecentTerminalPane(in tree: SplitTree) -> PaneRuntime? {
        let panes = tree.allPanes
        for id in tree.focusHistory {
            if let pane = panes.first(where: { $0.id == id }), pane.kind == .terminal {
                return pane
            }
        }
        return panes.first { $0.kind == .terminal }
    }

    /// Splits the pane with `targetPaneID`, wherever it lives in the tree —
    /// not necessarily `focusedPaneID` (#0282's XPC `pane split` verb, whose
    /// target is resolved upstream via `BattyTargetResolver`'s explicit-flag
    /// → env → focused-element chain and handed here as a plain id). Mirrors
    /// `splitFocusedPane`'s even 1/n chain-rebalance (#0255) via the same
    /// `inserting`/`rebalancingChain` machinery.
    ///
    /// Returns `nil` when `targetPaneID` is not present in this tree — the
    /// stale/unknown-id case the caller (`AppStateStore.splitPane`) must
    /// turn into a visible XPC failure (exit `4`), not a silent no-op.
    ///
    /// **Focus decision:** `focusedPaneID` moves to the new pane only when
    /// `targetPaneID` was already this tree's focused pane — matching
    /// `splitFocusedPane`'s existing behavior for that case. Splitting an
    /// explicitly-named pane that is *not* currently focused (an agent
    /// targeting a sibling pane, or any pane in a background session) never
    /// moves this tree's focus: the caller named a pane, not "make this the
    /// new focus," and a background session's own focus must stay exactly
    /// where the user left it (#0257) rather than jump to a pane they never
    /// asked to look at. This is symmetric for foreground and background
    /// targets — same rule either way, no special-casing on which session
    /// is selected.
    /// `isSessionSelected` (#0349) is the caller's answer to "is the Session
    /// this tree belongs to the one currently selected" — `SplitTree` has
    /// no notion of Sessions or window selection itself, so it can't derive
    /// the fact; it only carries it down to `PaneRuntime.init`'s
    /// `setUp(visible:)` so a non-terminal Pane created into a background
    /// Session (`AppStateStore.splitPane(id:...)`'s XPC `pane split` verb
    /// is the production path that does this — see that method's own
    /// "never touches `selectedSessionID`" doc note) starts `.suspended`
    /// instead of incorrectly starting `.active`. **No default** —
    /// both production callers (`AppStateStore.splitPane`, computing
    /// `window.selectedSessionID == session.id`; `WindowRuntime.createPane`,
    /// passing a literal `true` because it only ever splits the selected
    /// Session's own tree) already compute and pass a real value, so a
    /// silently-inserted `true` at every other call site could paper over
    /// a caller that should have computed the real fact and didn't. (For a
    /// related but different reason, `#0359` removed the `{ _ in nil }`
    /// default from the private `makePane`'s `tabLookup` parameter: a nil
    /// lookup silently tombstoned every `.followingTab` target.)
    @discardableResult
    public func splitPane(
        id targetPaneID: UUID,
        direction: SplitDirection,
        ratio: Double = 0.5,
        command: String? = nil,
        kind: PaneContentKind = .terminal,
        processStatusPid: Int32? = nil,
        path: String? = nil,
        tabs: [TabRuntime]? = nil,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil,
        isSessionSelected: Bool
    ) -> PaneRuntime? {
        guard let targetPane = root.findPane(id: targetPaneID) else { return nil }
        let newPane = Self.makePane(
            inheritingFrom: targetPane,
            in: self,
            command: command,
            kind: kind,
            processStatusPid: processStatusPid,
            path: path,
            tabs: tabs,
            contentFactory: contentFactory,
            isSessionSelected: isSessionSelected,
            tabLookup: Self.tabLookup(for: self)
        )
        if let sessionID {
            newPane.attachToSession(sessionID)
        }
        guard let newRoot = SplitTreeNode.inserting(
            newPane: newPane,
            adjacentTo: targetPaneID,
            direction: direction,
            ratio: ratio,
            into: root
        ) else {
            return nil
        }
        let result = SplitTreeNode.rebalancingChain(
            containing: newPane.id,
            direction: direction,
            in: newRoot,
            parentIsDSplit: false
        )
        root = result.updatedNode ?? newRoot
        if focusedPaneID == targetPaneID {
            focusedPaneID = newPane.id
        }
        return newPane
    }

    /// Delegates to `removePane(id:)` so the two never drift (#0337) — this
    /// has no callers at all outside `SplitTreePanePositionTests.swift`
    /// (the shipping ⌘W path is `WindowRuntime.closeFocusedTab()`, which
    /// never reaches this method), but keeping it a thin wrapper means it
    /// automatically gets the same recency-based successor choice rather
    /// than needing its own copy to stay in sync.
    public func removeFocusedPane() {
        let leaves = root.allLeafPanes
        guard leaves.count > 1 else { return }
        removePane(id: focusedPaneID)
    }

    /// Removes a pane by id. Returns `true` when the tree became empty
    /// (the removed pane was the only one). Callers should treat that as
    /// "session is now empty and should be closed."
    ///
    /// **Focus successor (#0337):** when the removed pane was the focused
    /// one, the replacement is chosen in this order: (1) the most recently
    /// focused surviving, *visible* pane from `focusHistory`; (2) the
    /// nearest visible leaf of the sibling subtree that absorbed the closed
    /// pane's space (`SplitTreeNode.siblingSubtree`) — the geometric
    /// neighbor #0021 originally deferred; (3) the first visible leaf
    /// anywhere in the tree; (4) `firstLeafPaneID` as the absolute last
    /// resort, which can be hidden if literally every remaining pane is
    /// hidden. Step 4 landing on a hidden pane is intentional and matches
    /// pre-#0337 behavior — the caller (`WindowRuntime.closePane`) is the
    /// one that un-hides it as a backstop, since un-hiding has Runtime-layer
    /// side effects (`TerminalHostStore` placements, content lifecycle)
    /// that this Model-layer type must not perform itself.
    @discardableResult
    public func removePane(id: UUID) -> Bool {
        guard let newRoot = SplitTreeNode.removingPane(id, from: root) else {
            focusHistory.removeAll()
            return true
        }
        let sibling = SplitTreeNode.siblingSubtree(of: id, in: root)
        root = newRoot
        focusHistory.removeAll { $0 == id || !newRoot.contains(paneID: $0) }
        if !newRoot.contains(paneID: focusedPaneID) {
            focusedPaneID = Self.resolveSuccessor(sibling: sibling, in: newRoot, history: focusHistory)
        }
        return false
    }

    private static func resolveSuccessor(
        sibling: SplitTreeNode?,
        in newRoot: SplitTreeNode,
        history: [UUID]
    ) -> UUID {
        if let fromHistory = history.first(where: { newRoot.findPane(id: $0)?.isHidden == false }) {
            return fromHistory
        }
        if let visibleSiblingLeaf = sibling?.firstVisibleLeafPaneID {
            return visibleSiblingLeaf
        }
        return newRoot.firstVisibleLeafPaneID ?? newRoot.firstLeafPaneID
    }

    public func updateRatio(forSplitID id: UUID, to newRatio: Double) {
        let clamped = max(0.05, min(0.95, newRatio))
        root = SplitTreeNode.updatingRatio(in: root, forID: id, to: clamped)
    }

    /// Which arrow of a Cmd-Ctrl-arrow resize was pressed. Deliberately a
    /// distinct type from `PaneFocusDirection` (Commands layer,
    /// `PaneFocus.swift`) even though the four cases mirror it exactly —
    /// that type belongs to the Commands layer, which already depends on
    /// `SplitTree`, and this Model-layer file should not depend back on it.
    public enum ResizeDirection: Sendable {
        case left, right, up, down
    }

    /// Step applied per Cmd-Ctrl-arrow press, per PRD.md §6.4 "Panes &
    /// splits" ("Keyboard resize: Cmd-Ctrl-arrows resize the split
    /// containing focus by ±5%").
    public static let resizeStep: Double = 0.05

    /// Resizes the Split containing focus by `resizeStep`, per Cmd-Ctrl-arrow
    /// (#0325). "The Split containing focus" resolves to the *deepest*
    /// ancestor of `focusedPaneID` whose `direction` matches the arrow's
    /// axis (`.left`/`.right` need a `.horizontal` ancestor, `.up`/`.down` a
    /// `.vertical` one) — not necessarily the immediate parent, since a
    /// perpendicular parent split has no meaningful effect along that axis
    /// and the search walks past it to the next ancestor out. No matching
    /// ancestor anywhere on the path (a single unsplit pane, or every
    /// ancestor is perpendicular) is a silent no-op — nothing visibly
    /// resizes, and nothing should.
    ///
    /// `.left`/`.up` decrease the ratio (shrink the left/top child, grow the
    /// right/bottom child); `.right`/`.down` increase it — each arrow moves
    /// the divider in its own geographic direction, the same way dragging it
    /// that way with the mouse would. Whether that grows or shrinks the
    /// *focused* pane specifically depends on which side of the divider it
    /// sits on; e.g. a pane in the right half growing on `.left` (the
    /// divider moves toward its neighbor) is this rule in action.
    /// `updateRatio` supplies the existing 0.05–0.95 clamp used by the
    /// divider-drag path, so a pane can never be resized to zero width.
    public func resizeFocusedSplit(_ direction: ResizeDirection) {
        let axis: SplitDirection
        let sign: Double
        switch direction {
        case .left:  axis = .horizontal; sign = -1
        case .right: axis = .horizontal; sign = 1
        case .up:    axis = .vertical;   sign = -1
        case .down:  axis = .vertical;   sign = 1
        }
        guard let splitID = root.nearestAncestorSplitID(containing: focusedPaneID, matchingAxis: axis),
              let currentRatio = root.ratio(forSplitID: splitID) else {
            logger.debug("split-tree: resize no-op reason=no-matching-ancestor direction=\(String(describing: direction), privacy: .public)")
            return
        }
        updateRatio(forSplitID: splitID, to: currentRatio + sign * Self.resizeStep)
    }

    /// Swaps the positions of two leaf panes in the tree. The split structure
    /// and ratios are unchanged; only the leaf contents trade places.
    /// No-op if either id is not found.
    public func swapPanes(id idA: UUID, with idB: UUID) {
        guard idA != idB else {
            logger.notice("split-tree: swapPanes no-op reason=same-id id=\(idA, privacy: .public)")
            return
        }
        guard let paneA = root.findPane(id: idA) else {
            logger.notice("split-tree: swapPanes no-op missing=A id=\(idA, privacy: .public) other=\(idB, privacy: .public)")
            return
        }
        guard let paneB = root.findPane(id: idB) else {
            logger.notice("split-tree: swapPanes no-op missing=B id=\(idB, privacy: .public) other=\(idA, privacy: .public)")
            return
        }
        root = SplitTreeNode.swapping(paneA: paneA, paneB: paneB, in: root)
    }
}

extension SplitTreeNode {
    static func swapping(paneA: PaneRuntime, paneB: PaneRuntime, in node: SplitTreeNode) -> SplitTreeNode {
        switch node {
        case .leaf(let pane):
            if pane.id == paneA.id { return .leaf(paneB) }
            if pane.id == paneB.id { return .leaf(paneA) }
            return node
        case .split(let id, let dir, let ratio, let left, let right):
            return .split(
                id: id,
                direction: dir,
                ratio: ratio,
                left: swapping(paneA: paneA, paneB: paneB, in: left),
                right: swapping(paneA: paneA, paneB: paneB, in: right)
            )
        }
    }

    static func updatingRatio(in node: SplitTreeNode, forID id: UUID, to newRatio: Double) -> SplitTreeNode {
        switch node {
        case .leaf:
            return node
        case .split(let nodeID, let dir, let ratio, let left, let right):
            if nodeID == id {
                return .split(id: nodeID, direction: dir, ratio: newRatio, left: left, right: right)
            }
            return .split(
                id: nodeID,
                direction: dir,
                ratio: ratio,
                left: updatingRatio(in: left, forID: id, to: newRatio),
                right: updatingRatio(in: right, forID: id, to: newRatio)
            )
        }
    }

    /// Deepest ancestor split containing `paneID` whose `direction` matches
    /// `axis` — see `SplitTree.resizeFocusedSplit` for why this walks past a
    /// nearer, perpendicular ancestor instead of stopping there. `nil` when
    /// `paneID` isn't in this subtree, or no ancestor on its path matches.
    func nearestAncestorSplitID(containing paneID: UUID, matchingAxis axis: SplitDirection) -> UUID? {
        ancestorSearch(containing: paneID, matchingAxis: axis).matchID
    }

    private func ancestorSearch(
        containing paneID: UUID,
        matchingAxis axis: SplitDirection
    ) -> (containsTarget: Bool, matchID: UUID?) {
        switch self {
        case .leaf(let pane):
            return (pane.id == paneID, nil)
        case .split(let id, let dir, _, let left, let right):
            let leftResult = left.ancestorSearch(containing: paneID, matchingAxis: axis)
            if leftResult.containsTarget {
                return (true, leftResult.matchID ?? (dir == axis ? id : nil))
            }
            let rightResult = right.ancestorSearch(containing: paneID, matchingAxis: axis)
            if rightResult.containsTarget {
                return (true, rightResult.matchID ?? (dir == axis ? id : nil))
            }
            return (false, nil)
        }
    }

    /// Current ratio of the split with `id`, or `nil` if not found.
    func ratio(forSplitID id: UUID) -> Double? {
        switch self {
        case .leaf:
            return nil
        case .split(let nodeID, _, let ratio, let left, let right):
            if nodeID == id { return ratio }
            return left.ratio(forSplitID: id) ?? right.ratio(forSplitID: id)
        }
    }

    static func removingPane(_ id: UUID, from node: SplitTreeNode) -> SplitTreeNode? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? nil : node
        case .split(let nodeID, let dir, let ratio, let left, let right):
            let newLeft = removingPane(id, from: left)
            let newRight = removingPane(id, from: right)
            switch (newLeft, newRight) {
            case (nil, nil):
                return nil
            case (nil, let r?):
                return r
            case (let l?, nil):
                return l
            case (let l?, let r?):
                return .split(id: nodeID, direction: dir, ratio: ratio, left: l, right: r)
            }
        }
    }

    static func inserting(
        newPane: PaneRuntime,
        adjacentTo paneID: UUID,
        direction: SplitDirection,
        ratio: Double,
        into node: SplitTreeNode
    ) -> SplitTreeNode? {
        switch node {
        case .leaf(let pane) where pane.id == paneID:
            return .split(
                id: UUID(),
                direction: direction,
                ratio: ratio,
                left: .leaf(pane),
                right: .leaf(newPane)
            )
        case .leaf:
            return nil
        case .split(let nodeID, let dir, let r, let left, let right):
            if let newLeft = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: left
            ) {
                return .split(id: nodeID, direction: dir, ratio: r, left: newLeft, right: right)
            }
            if let newRight = inserting(
                newPane: newPane,
                adjacentTo: paneID,
                direction: direction,
                ratio: ratio,
                into: right
            ) {
                return .split(id: nodeID, direction: dir, ratio: r, left: left, right: newRight)
            }
            return nil
        }
    }

    // MARK: - Same-axis equalization

    /// Finds the maximal contiguous same-direction chain containing `paneID` and rebalances
    /// every ratio in that chain so all its leaf units get an equal fraction (1/n).
    /// A "chain leaf unit" is either an actual leaf pane or a perpendicular-direction subtree
    /// (which counts as one opaque unit). Perpendicular splits are never rebalanced here.
    ///
    /// `parentIsDSplit`: pass `true` when the calling split's direction equals `direction`.
    ///   The chain root is the highest D-split that has no D-split parent — identified by
    ///   `parentIsDSplit == false`. Rebalancing is applied only at the chain root.
    fileprivate static func rebalancingChain(
        containing paneID: UUID,
        direction: SplitDirection,
        in node: SplitTreeNode,
        parentIsDSplit: Bool
    ) -> ChainSearchResult {
        switch node {
        case .leaf(let pane):
            guard pane.id == paneID else { return .notFound }
            return .foundInDChain(node)

        case .split(let id, let dir, let ratio, let left, let right):
            if dir == direction {
                // We're in a D-split. Recurse with parentIsDSplit=true so children know they
                // are inside a D-chain and should not trigger chain-root rebalancing.
                let leftResult = rebalancingChain(containing: paneID, direction: direction, in: left, parentIsDSplit: true)
                let rightResult = rebalancingChain(containing: paneID, direction: direction, in: right, parentIsDSplit: true)

                switch (leftResult, rightResult) {
                case (.notFound, .notFound):
                    return .notFound

                case (.foundInDChain(let newLeft), _):
                    let updated = SplitTreeNode.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right)
                    if !parentIsDSplit {
                        // This is the chain root: apply equalization to the whole chain.
                        return .foundInDChain(rebalancedChain(updated, direction: direction))
                    }
                    return .foundInDChain(updated)

                case (_, .foundInDChain(let newRight)):
                    let updated = SplitTreeNode.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight)
                    if !parentIsDSplit {
                        return .foundInDChain(rebalancedChain(updated, direction: direction))
                    }
                    return .foundInDChain(updated)

                // paneID was found but its path crossed a perpendicular split inside this D-subtree.
                // Propagate without rebalancing the outer D-chain.
                case (.foundBelowBreak(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))

                case (_, .foundBelowBreak(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                }
            } else {
                // Non-D split breaks the chain. Recurse with parentIsDSplit=false so the next
                // D-split below will be treated as its own chain root.
                let leftResult = rebalancingChain(containing: paneID, direction: direction, in: left, parentIsDSplit: false)
                let rightResult = rebalancingChain(containing: paneID, direction: direction, in: right, parentIsDSplit: false)

                switch (leftResult, rightResult) {
                case (.notFound, .notFound):
                    return .notFound
                case (.foundInDChain(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))
                case (.foundBelowBreak(let newLeft), _):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: newLeft, right: right))
                case (_, .foundInDChain(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                case (_, .foundBelowBreak(let newRight)):
                    return .foundBelowBreak(.split(id: id, direction: dir, ratio: ratio, left: left, right: newRight))
                }
            }
        }
    }

    /// Sets the ratio of every D-direction split in this subtree so all visible
    /// chain leaves get equal fractions. Perpendicular splits are treated as
    /// single opaque units. Hidden leaves receive a ratio of 0 so they consume
    /// no rendered space and the stored ratio is restored when un-hidden by the
    /// next equalization pass on the next split.
    ///
    /// When all leaves in both arms are hidden (`total == 0`), the existing
    /// ratio is preserved unchanged — an all-hidden subtree is an edge case
    /// that cannot occur under the "≥1 visible pane" invariant, but the guard
    /// keeps ratio finite if the invariant is momentarily violated.
    fileprivate static func rebalancedChain(_ node: SplitTreeNode, direction: SplitDirection) -> SplitTreeNode {
        switch node {
        case .leaf:
            return node
        case .split(let id, let dir, _, let left, let right):
            guard dir == direction else { return node }
            let leftCount = countChainLeaves(left, direction: direction)
            let rightCount = countChainLeaves(right, direction: direction)
            let total = leftCount + rightCount
            guard total > 0 else {
                // All hidden — preserve the stored ratio unchanged.
                return node
            }
            return .split(
                id: id,
                direction: dir,
                ratio: Double(leftCount) / Double(total),
                left: rebalancedChain(left, direction: direction),
                right: rebalancedChain(right, direction: direction)
            )
        }
    }

    /// Counts the number of visible "chain leaf units" in a same-direction chain.
    /// Hidden leaves count as 0; visible leaves count as 1.
    /// Perpendicular-direction subtrees count as 0 if entirely hidden, 1 otherwise.
    /// This ensures equalization after a split distributes space only among
    /// visible panes — a hidden pane does not receive a fractional share (#0256).
    fileprivate static func countChainLeaves(_ node: SplitTreeNode, direction: SplitDirection) -> Int {
        switch node {
        case .leaf(let pane):
            return pane.isHidden ? 0 : 1
        case .split(_, let dir, _, let left, let right):
            guard dir == direction else {
                // Perpendicular subtree counts as one opaque unit if any pane is visible.
                return node.isEntirelyHidden ? 0 : 1
            }
            return countChainLeaves(left, direction: direction) + countChainLeaves(right, direction: direction)
        }
    }

    // MARK: - Pane positions (#0259)

    /// Column/row coordinates for every leaf pane in this subtree, derived
    /// purely from tree shape (no rendered geometry involved) so it works
    /// identically for the selected session, background sessions, hidden
    /// panes, and headless callers like the CLI (#0257).
    ///
    /// The tree is projected onto a virtual grid where every subtree
    /// occupies a rectangle: a `.horizontal` split places its children's
    /// rectangles side by side (the right child's columns start after the
    /// left child's full column span), a `.vertical` split stacks them
    /// (rows advance by the upper child's full row span), and a leaf is the
    /// top-left cell of its rectangle. Sibling rectangles are disjoint along
    /// the split axis, so every pane gets a unique coordinate for any tree
    /// shape. Span reservation is what makes mixed nesting safe: in
    /// `horizontal(vertical(horizontal(A,B), C), D)` the left subtree spans
    /// two columns, so D lands at 3/1 instead of colliding with B at 2/1 —
    /// the coordinates order panes the same way their rendered frame origins
    /// do, at the cost of an occasional gap in the numbering (there is no
    /// pane at 2/2 or 3/... other than D). Hidden panes are not
    /// special-cased: they occupy the same tree slot whether hidden or not,
    /// so they keep their coordinates (#0256).
    public func panePositions() -> [UUID: PanePosition] {
        var result: [UUID: PanePosition] = [:]
        assignPositions(into: &result, column: 1, row: 1)
        return result
    }

    /// The (columns, rows) extent of the virtual-grid rectangle this
    /// subtree occupies: a split sums its children's spans along the split
    /// axis and takes the max across it.
    private var gridSpan: (columns: Int, rows: Int) {
        switch self {
        case .leaf:
            return (1, 1)
        case .split(_, .horizontal, _, let left, let right):
            let l = left.gridSpan
            let r = right.gridSpan
            return (l.columns + r.columns, max(l.rows, r.rows))
        case .split(_, .vertical, _, let left, let right):
            let l = left.gridSpan
            let r = right.gridSpan
            return (max(l.columns, r.columns), l.rows + r.rows)
        }
    }

    private func assignPositions(
        into result: inout [UUID: PanePosition],
        column: Int,
        row: Int
    ) {
        switch self {
        case .leaf(let pane):
            result[pane.id] = PanePosition(column: column, row: row)
        case .split(_, .horizontal, _, let left, let right):
            left.assignPositions(into: &result, column: column, row: row)
            right.assignPositions(into: &result, column: column + left.gridSpan.columns, row: row)
        case .split(_, .vertical, _, let left, let right):
            left.assignPositions(into: &result, column: column, row: row)
            right.assignPositions(into: &result, column: column, row: row + left.gridSpan.rows)
        }
    }
}

/// A pane's column/row coordinates within its session's split layout, as
/// shown in the sidebar pane row (#0259): `1/1` is the first pane, `2/1` is
/// a horizontal sibling (second column, first row), `1/3` is the third pane
/// in a vertical chain (first column, third row).
public struct PanePosition: Hashable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public var label: String { "\(column)/\(row)" }
}

extension SplitTree {
    /// Column/row coordinates for every pane currently in the tree, keyed by
    /// pane id. See `SplitTreeNode.panePositions()` for the derivation rule.
    public var panePositions: [UUID: PanePosition] {
        root.panePositions()
    }

    /// All panes ordered column-major — every pane in column 1 top-to-bottom,
    /// then column 2, and so on — for the sidebar pane list (#0263). Each
    /// column's vertically-stacked panes stay grouped together before the
    /// next column starts. `allPanes` is tree-traversal order (depth-first),
    /// which is not column-major in general (e.g.
    /// `horizontal(vertical(A, C), B)` lists A, C, B in traversal order,
    /// which happens to already be column-major there, but
    /// `horizontal(vertical(A, C), horizontal(B, D))`-style layouts diverge).
    /// This is derived fresh from `panePositions` each time rather than
    /// stored, so it self-maintains through splits, closes, and
    /// rearrangements without any ordering state to keep in sync.
    public var panesSortedByColumnThenRow: [PaneRuntime] {
        let positions = panePositions
        return allPanes.sorted { lhs, rhs in
            let lhsPosition = positions[lhs.id] ?? PanePosition(column: 0, row: 0)
            let rhsPosition = positions[rhs.id] ?? PanePosition(column: 0, row: 0)
            if lhsPosition.column != rhsPosition.column {
                return lhsPosition.column < rhsPosition.column
            }
            return lhsPosition.row < rhsPosition.row
        }
    }
}
