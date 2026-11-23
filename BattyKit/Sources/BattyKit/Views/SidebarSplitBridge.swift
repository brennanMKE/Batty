// SidebarSplitBridge.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "SidebarSplitBridge")

/// The `compactSidebar` experiment's AppKit side: finds the `NSSplitView`
/// behind the window's `NavigationSplitView` and owns the Sidebar's style
/// changes. `updateNSView` does nothing, so no SwiftUI update calls AppKit
/// from here.
struct SidebarSplitBridge: NSViewRepresentable {
    let windowRuntime: WindowRuntime
    let store: AppStateStore
    let railWidth: CGFloat

    func makeNSView(context: Context) -> SidebarSplitBridgeView {
        SidebarSplitBridgeView(windowRuntime: windowRuntime, store: store, railWidth: railWidth)
    }

    func updateNSView(_ nsView: SidebarSplitBridgeView, context: Context) {}
}

/// The single writer of `WindowRuntime.sidebarStyle`. Both writes are
/// event-origin and synchronous: the style command arrives as a
/// `.battyToggleSidebarStyle` post from a menu, key-monitor or palette
/// event, and a divider drag ends inside this view's `.leftMouseDown`
/// monitor, which runs `NSSplitView`'s own tracking loop and commits when it
/// returns. Nothing is written while the divider moves. The `.battyToggleSidebar`
/// post is observed too, so a show can land at a width chosen while hidden.
final class SidebarSplitBridgeView: NSView {
    let windowRuntime: WindowRuntime
    let store: AppStateStore
    let railWidth: CGFloat
    /// Only the key window acts on the style command.
    var isKeyTarget: () -> Bool

    private(set) weak var splitView: NSSplitView?
    private weak var splitViewController: NSSplitViewController?
    private var mouseMonitor: Any?
    private var observingCommand = false
    /// The names width to come back to from the rail. Not observed.
    private(set) var lastNamesWidth: CGFloat?
    /// The width the next ⌘B show lands at, set by a style command while the
    /// Sidebar is hidden. Not observed.
    private(set) var pendingWidth: CGFloat?

    init(windowRuntime: WindowRuntime, store: AppStateStore, railWidth: CGFloat, isKeyTarget: (() -> Bool)? = nil) {
        self.windowRuntime = windowRuntime
        self.store = store
        self.railWidth = railWidth
        self.isKeyTarget = isKeyTarget ?? { [weak store, weak windowRuntime] in
            guard let store, let windowRuntime else { return false }
            return store.keyWindowRuntime()?.id == windowRuntime.id
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopObserving() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        resolveSplitView()
        startObserving()
    }

    // MARK: - Split view

    @discardableResult
    func resolveSplitView() -> NSSplitView? {
        if let splitView { return splitView }
        var candidate = superview
        while let view = candidate {
            if let found = view as? NSSplitView, found.arrangedSubviews.count >= 2 {
                splitView = found
                splitViewController = found.delegate as? NSSplitViewController
                return found
            }
            candidate = view.superview
        }
        return nil
    }

    private var sidebarItem: NSSplitViewItem? {
        splitViewController?.splitViewItems.first
    }

    var isSidebarCollapsed: Bool {
        sidebarItem?.isCollapsed ?? false
    }

    var sidebarWidth: CGFloat? {
        splitView?.arrangedSubviews.first?.frame.width
    }

    // MARK: - Style command

    private func startObserving() {
        if !observingCommand {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(toggleStyleCommand(_:)),
                name: .battyToggleSidebarStyle,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(toggleSidebarCommand(_:)),
                name: .battyToggleSidebar,
                object: nil
            )
            observingCommand = true
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self else { return event }
                return self.handleMouseDown(event) ? nil : event
            }
        }
    }

    private func stopObserving() {
        if observingCommand {
            NotificationCenter.default.removeObserver(self, name: .battyToggleSidebarStyle, object: nil)
            NotificationCenter.default.removeObserver(self, name: .battyToggleSidebar, object: nil)
            observingCommand = false
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    @objc private func toggleStyleCommand(_ notification: Notification) {
        guard isKeyTarget() else { return }
        apply(windowRuntime.sidebarStyle.toggled)
    }

    /// SwiftUI's column minimum follows `sidebarStyle`, but only on its next
    /// update, after `setPosition` has run and been clamped. Setting the
    /// item's minimum here first lets the move land; SwiftUI then writes the
    /// same value. AppKit only, from an event; writes no observed state.
    private func setSidebarMinimum(for style: SidebarStyle) {
        sidebarItem?.minimumThickness = SidebarRailMetrics.minimum(for: style, railWidth: railWidth)
    }

    /// Switches the Sidebar to `style` at its width. A hidden Sidebar stays
    /// hidden: only the style changes, and the next ⌘B show uses it.
    func apply(_ style: SidebarStyle) {
        guard let splitView = resolveSplitView() else {
            logger.error("sidebar style: no NSSplitView above the detail column")
            return
        }
        // Moving a collapsed item means showing it, which resizes the detail
        // column and every terminal in it. So a hidden Sidebar only records
        // its target width; `showAtPendingWidth` applies it in the same step
        // that shows it, so the terminals see one resize.
        if isSidebarCollapsed {
            if windowRuntime.sidebarStyle != style {
                windowRuntime.sidebarStyle = style
            }
            pendingWidth = SidebarRailMetrics.targetWidth(for: style, railWidth: railWidth, lastNamesWidth: lastNamesWidth)
            return
        }
        pendingWidth = nil
        if windowRuntime.sidebarStyle == .names, style == .symbols, let width = sidebarWidth {
            lastNamesWidth = width
        }
        if windowRuntime.sidebarStyle != style {
            windowRuntime.sidebarStyle = style
        }
        setSidebarMinimum(for: style)
        let target = SidebarRailMetrics.targetWidth(for: style, railWidth: railWidth, lastNamesWidth: lastNamesWidth)
        splitView.setPosition(target, ofDividerAt: 0)
    }

    /// ⌘B, before SwiftUI acts on it. Hiding names records its width for a
    /// later switch back from the rail made while hidden; showing with a
    /// pending width shows it at that width.
    @objc private func toggleSidebarCommand(_ notification: Notification) {
        guard isKeyTarget() else { return }
        if isSidebarCollapsed {
            showAtPendingWidth()
        } else if windowRuntime.sidebarStyle == .names, let width = sidebarWidth {
            lastNamesWidth = width
        }
    }

    /// A collapsed item comes back at its width from before it collapsed,
    /// clamped to its range. Pinning the range to the pending width for the
    /// show makes `NSSplitView` lay the detail column out once, at the final
    /// width. SwiftUI's own show then finds the item already shown. AppKit
    /// only, from the ⌘B event; writes no observed state.
    func showAtPendingWidth() {
        guard let item = sidebarItem, item.isCollapsed, let target = pendingWidth else { return }
        pendingWidth = nil
        let maximum = item.maximumThickness
        item.minimumThickness = target
        item.maximumThickness = target
        item.isCollapsed = false
        item.maximumThickness = maximum
        setSidebarMinimum(for: windowRuntime.sidebarStyle)
    }

    // MARK: - Divider drag

    /// True when the press was on the divider and has been tracked to its
    /// release. Every other press, including every one on a Pane, the
    /// outline or the footer, hit-tests to its own view and passes through.
    private func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.clickCount == 1,
              let splitView = resolveSplitView(), !isSidebarCollapsed else { return false }
        let root = window.contentView?.superview ?? window.contentView
        guard root?.hitTest(event.locationInWindow) === splitView else { return false }
        let startWidth = sidebarWidth
        beginDividerDrag()
        splitView.mouseDown(with: event)
        finishDividerDrag(startWidth: startWidth)
        return true
    }

    /// Names rests at 180 or wider, so the drag alone lowers the minimum to
    /// the rail; `finishDividerDrag` puts back the landed style's minimum.
    func beginDividerDrag() {
        setSidebarMinimum(for: .symbols)
    }

    /// The commit after a divider drag: snap to the rail, to the names
    /// minimum, or keep the width.
    func finishDividerDrag(startWidth: CGFloat? = nil) {
        guard let splitView = resolveSplitView(), !isSidebarCollapsed, let width = sidebarWidth else {
            setSidebarMinimum(for: windowRuntime.sidebarStyle)
            return
        }
        pendingWidth = nil
        let resolved = SidebarRailMetrics.resolveDragEnd(width: width, railWidth: railWidth)
        if windowRuntime.sidebarStyle == .names, resolved.style == .symbols {
            lastNamesWidth = startWidth.map { Swift.max($0, SidebarRailMetrics.namesMin) }
        }
        if windowRuntime.sidebarStyle != resolved.style {
            windowRuntime.sidebarStyle = resolved.style
        }
        setSidebarMinimum(for: resolved.style)
        if abs(width - resolved.width) > 0.5 {
            splitView.setPosition(resolved.width, ofDividerAt: 0)
        }
    }
}
