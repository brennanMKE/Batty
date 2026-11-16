// SessionSidebarOutline.swift

import AppKit
import SwiftUI

/// The Sidebar's colors, from the window's Theme and see-through state.
struct SidebarRowStyle: Equatable {
    var accent: Color?
    var sidebarFill: Color?
    var selectionTint: Color?
}

/// The Sidebar's sheet triggers, owned by `SessionSidebarView`'s `@State`.
struct SidebarRowActions {
    var onRename: (SessionRuntime) -> Void = { _ in }
    var onTheme: (UUID) -> Void = { _ in }
    var onSetColor: (UUID) -> Void = { _ in }
    var onBackground: (UUID) -> Void = { _ in }
    var onPaneBackground: (UUID) -> Void = { _ in }
}

/// The Sidebar's Session and Pane rows: an `NSOutlineView` with one
/// `NSHostingView` cell per row. A SwiftUI `List` or `Table` posts
/// update-constraints requests for every cell whenever its selection, any
/// row or an injected environment value changes, so a Session switch cost
/// grew with the number of Sessions (#0619). Here each cell is its own
/// SwiftUI root, so a switch re-renders only the two cells whose
/// `SessionRuntime.isSelected` flips, and the outline moves its native
/// selection. Arrow keys, type-select, disclosure and VoiceOver's selected
/// row stay native.
struct SessionSidebarOutline: NSViewRepresentable {
    static let dragType = NSPasteboard.PasteboardType("co.sstools.batty.sidebar-session")

    let windowRuntime: WindowRuntime
    let store: AppStateStore
    let style: SidebarRowStyle
    let actions: SidebarRowActions

    func makeCoordinator() -> SessionSidebarCoordinator {
        SessionSidebarCoordinator(windowRuntime: windowRuntime, store: store, style: style, actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SessionSidebarOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.allowsTypeSelect = true
        outline.autosaveExpandedItems = false
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.setAccessibilityIdentifier("session-sidebar")
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.apply(outline: outline)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let outline = scroll.documentView as? SessionSidebarOutlineView else { return }
        context.coordinator.update(representable: self, outline: outline)
    }
}

final class SessionSidebarOutlineView: NSOutlineView {}

final class SessionSidebarCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let sessionCellID = NSUserInterfaceItemIdentifier("session-cell")
    private static let paneCellID = NSUserInterfaceItemIdentifier("pane-cell")

    let windowRuntime: WindowRuntime
    let store: AppStateStore
    private(set) var style: SidebarRowStyle
    private(set) var actions: SidebarRowActions
    /// What the outline shows: the Sessions and each Session's Panes as of
    /// the last reload. The data source answers from these, never from the
    /// live model, so the outline's row indices always match its own items.
    private var sessions: [SessionRuntime] = []
    private var panes: [ObjectIdentifier: [PaneRuntime]] = [:]
    /// Set while `apply` drives the outline, so the selection and expansion
    /// notifications AppKit posts for those calls are not read as the user's.
    private var applyingModelChange = false

    init(windowRuntime: WindowRuntime, store: AppStateStore, style: SidebarRowStyle, actions: SidebarRowActions) {
        self.windowRuntime = windowRuntime
        self.store = store
        self.style = style
        self.actions = actions
    }

    func update(representable: SessionSidebarOutline, outline: NSOutlineView) {
        actions = representable.actions
        apply(outline: outline, style: representable.style)
    }

    /// The model → AppKit direction, run only from the representable's
    /// make and update (and from a rejected user selection, to snap back).
    /// Its reads of observed state are what the update depends on. It writes
    /// no observed state and changes no responder, and calls AppKit only
    /// where the outline differs from the model: a Session switch is one
    /// `selectRowIndexes`. The structure calls run only when the Sessions or
    /// a Session's Panes change.
    func apply(outline: NSOutlineView, style newStyle: SidebarRowStyle? = nil) {
        applyingModelChange = true
        defer { applyingModelChange = false }

        let liveSessions = windowRuntime.sessions
        let livePanes = Dictionary(uniqueKeysWithValues: liveSessions.map {
            (ObjectIdentifier($0), $0.tree.panesSortedByColumnThenRow)
        })
        if liveSessions.map(ObjectIdentifier.init) != sessions.map(ObjectIdentifier.init) {
            sessions = liveSessions
            panes = livePanes
            outline.reloadData()
        } else {
            for session in sessions {
                let key = ObjectIdentifier(session)
                let live = livePanes[key] ?? []
                if live.map(ObjectIdentifier.init) != (panes[key] ?? []).map(ObjectIdentifier.init) {
                    panes[key] = live
                    outline.reloadItem(session, reloadChildren: true)
                }
            }
        }

        for session in sessions where session.isPaneListExpanded != outline.isItemExpanded(session) {
            if session.isPaneListExpanded {
                outline.expandItem(session)
            } else {
                outline.collapseItem(session)
            }
        }

        if let newStyle, newStyle != style {
            style = newStyle
            outline.enumerateAvailableRowViews { rowView, row in
                if let rowView = rowView as? SidebarOutlineRowView {
                    self.styleRowView(rowView, isSessionRow: outline.item(atRow: row) is SessionRuntime)
                }
                if let cell = rowView.view(atColumn: 0) as? SidebarCellHostingView, let item = outline.item(atRow: row) {
                    self.configure(cell, for: item)
                }
            }
        }

        if let selected = windowRuntime.selectedSession {
            let row = outline.row(forItem: selected)
            if row >= 0, outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return sessions.count }
        guard let session = item as? SessionRuntime else { return 0 }
        return panes[ObjectIdentifier(session)]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let session = item as? SessionRuntime else { return sessions[index] }
        return panes[ObjectIdentifier(session)]?[index] as Any
    }

    /// Every Session has a disclosure triangle, single-Pane ones included.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SessionRuntime
    }

    // MARK: - Rows and cells

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarOutlineRowView()
        styleRowView(rowView, isSessionRow: item is SessionRuntime)
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = item is SessionRuntime ? Self.sessionCellID : Self.paneCellID
        let cell: SidebarCellHostingView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCellHostingView {
            cell = reused
        } else {
            cell = SidebarCellHostingView(rootView: SidebarCellRoot(content: AnyView(EmptyView()), emphasized: false, selected: false))
            cell.sizingOptions = []
            cell.identifier = identifier
        }
        configure(cell, for: item)
        return cell
    }

    private func styleRowView(_ rowView: SidebarOutlineRowView, isSessionRow: Bool) {
        rowView.fill = style.sidebarFill.map(NSColor.init)
        rowView.tint = isSessionRow ? style.selectionTint.map(NSColor.init) : nil
    }

    private func configure(_ cell: SidebarCellHostingView, for item: Any) {
        if let session = item as? SessionRuntime {
            cell.content = SessionSidebarView.sessionCell(
                session: session,
                store: store,
                windowRuntime: windowRuntime,
                accent: style.accent,
                actions: { [weak self] in self?.actions ?? SidebarRowActions() }
            )
        } else if let pane = item as? PaneRuntime,
                  let session = sessions.first(where: { panes[ObjectIdentifier($0)]?.contains { $0 === pane } == true }) {
            cell.content = SessionSidebarView.paneCell(
                pane: pane,
                session: session,
                windowRuntime: windowRuntime,
                accent: style.accent,
                onBackgroundSettings: { [weak self] in self?.actions.onPaneBackground(pane.id) }
            )
        }
    }

    // MARK: - Selection

    /// Pane rows are never selected: a click on one selects its Session
    /// through `PaneRow`'s tap, and arrow keys skip them (#0258).
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SessionRuntime
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? SessionRuntime)?.title
    }

    /// The AppKit → model direction: the user's click, arrow key or
    /// type-select, an event-origin write. `selectSessionFromSidebar` rejects
    /// anything that isn't a Session in this window, so while Sessions exist
    /// one is always selected (#0258). A rejected selection snaps the outline
    /// back to the model's.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingModelChange, let outline = notification.object as? NSOutlineView else { return }
        let item = outline.item(atRow: outline.selectedRow)
        windowRuntime.selectSessionFromSidebar(id: (item as? SessionRuntime)?.id)
        if (item as? SessionRuntime)?.id != windowRuntime.selectedSessionID {
            apply(outline: outline)
        }
    }

    // MARK: - Disclosure

    func outlineViewItemDidExpand(_ notification: Notification) {
        setExpanded(true, from: notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        setExpanded(false, from: notification)
    }

    /// The user's disclosure-triangle click.
    private func setExpanded(_ expanded: Bool, from notification: Notification) {
        guard !applyingModelChange,
              let session = notification.userInfo?["NSObject"] as? SessionRuntime,
              session.isPaneListExpanded != expanded else { return }
        session.isPaneListExpanded = expanded
    }

    // MARK: - Drag reorder

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let session = item as? SessionRuntime else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(session.id.uuidString, forType: SessionSidebarOutline.dragType)
        return pasteboardItem
    }

    /// Only this outline's own Session drags, always retargeted to a position
    /// between root rows: a drop on a Session goes before it, a drop among
    /// its Panes goes after it.
    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard (info.draggingSource as? NSOutlineView) === outlineView, draggedSessionIndex(info) != nil else { return [] }
        let target: Int
        if let session = item as? SessionRuntime, let position = sessions.firstIndex(where: { $0 === session }) {
            target = index == NSOutlineViewDropOnItemIndex ? position : position + 1
        } else if let pane = item as? PaneRuntime,
                  let position = sessions.firstIndex(where: { panes[ObjectIdentifier($0)]?.contains { $0 === pane } == true }) {
            target = position + 1
        } else {
            target = index == NSOutlineViewDropOnItemIndex ? sessions.count : index
        }
        outlineView.setDropItem(nil, dropChildIndex: target)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard item == nil, index >= 0, let from = draggedSessionIndex(info) else { return false }
        moveSession(from: from, toRootIndex: index)
        return true
    }

    /// The root drop index counts positions before the dragged row is
    /// removed, as `moveSessions(fromOffsets:toOffset:)` does.
    func moveSession(from source: Int, toRootIndex destination: Int) {
        windowRuntime.moveSessions(fromOffsets: IndexSet(integer: source), toOffset: destination)
    }

    private func draggedSessionIndex(_ info: NSDraggingInfo) -> Int? {
        guard let string = info.draggingPasteboard.string(forType: SessionSidebarOutline.dragType),
              let id = UUID(uuidString: string) else { return nil }
        return windowRuntime.sessions.firstIndex { $0.id == id }
    }
}

/// A cell's SwiftUI root. `emphasized` follows the row's selected-and-focused
/// state, so the selected row's text reads against the accent highlight;
/// `selected` bolds the selected row's text whether or not the window is key.
///
/// The full-height frame makes `NSHostingView` report the content's baseline
/// where it is drawn (centred in the row). AppKit places the disclosure
/// chevron from that baseline, so without it the chevron sits at the top.
struct SidebarCellRoot: View {
    let content: AnyView
    let emphasized: Bool
    let selected: Bool

    var body: some View {
        let base = content
            .bold(selected)
            .frame(maxHeight: .infinity)
        if emphasized {
            base
                .foregroundStyle(Color.white)
                .environment(\.backgroundProminence, .increased)
        } else {
            base
        }
    }
}

final class SidebarCellHostingView: NSHostingView<SidebarCellRoot> {
    var content = AnyView(EmptyView()) {
        didSet { render() }
    }

    /// Set by `SidebarOutlineRowView` when its selection or emphasis changes.
    var emphasized = false {
        didSet {
            if emphasized != oldValue { render() }
        }
    }

    /// Set by `SidebarOutlineRowView` when its selection changes.
    var selected = false {
        didSet {
            if selected != oldValue { render() }
        }
    }

    private func render() {
        rootView = SidebarCellRoot(content: content, emphasized: emphasized, selected: selected)
    }
}

/// Paints the themed or see-through sidebar fill, and on a selected Session
/// row a subtle tint instead of the system's selection block, which ignores
/// the themed sidebar (#0135). With no fill the row is the native source
/// list row.
final class SidebarOutlineRowView: NSTableRowView {
    var fill: NSColor? {
        didSet {
            needsDisplay = true
            syncCellEmphasis()
        }
    }
    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    override var isSelected: Bool {
        didSet { syncCellEmphasis() }
    }
    override var isEmphasized: Bool {
        didSet { syncCellEmphasis() }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        fill == nil ? super.interiorBackgroundStyle : .normal
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        syncCellEmphasis()
    }

    private func syncCellEmphasis() {
        let emphasized = isSelected && interiorBackgroundStyle == .emphasized
        for case let cell as SidebarCellHostingView in subviews {
            cell.emphasized = emphasized
            cell.selected = isSelected
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let fill else {
            super.drawBackground(in: dirtyRect)
            return
        }
        fill.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard fill != nil else {
            super.drawSelection(in: dirtyRect)
            return
        }
        if let tint {
            tint.setFill()
            bounds.fill(using: .sourceOver)
        }
    }
}
