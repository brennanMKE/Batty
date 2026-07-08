// PaneView.swift

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PaneView")


public struct PaneView: View {
    @Bindable public var pane: PaneRuntime
    @Bindable public var tree: SplitTree
    @Environment(\.appStateStore) private var appStore
    @Environment(\.isSelectedSession) private var isSessionSelected
    @Environment(\.themeChrome) private var themeChrome
    @Environment(\.paneAllottedSize) private var allottedSize
    @State private var bellFlashOpacity: Double = 0
    @State private var renamingTab: TabRuntime?
    @State private var renameDraft: String = ""
    @State private var paneWidth: CGFloat = 0
    @State private var paneHeight: CGFloat = 0
    @State private var frameInSession: CGRect = .zero

    /// Approximate per-character text width at the chip's font. Used to
    /// derive a string-level char budget from the per-chip pixel budget.
    private static let approxCharWidth: CGFloat = 7
    /// Per-chip non-text overhead (icon + close button + padding).
    private static let chipChromeWidth: CGFloat = 36
    /// SlidingTabBar's own per-bar overhead: 2×12 h-padding + 22 "+" button = 46,
    /// plus a small layout buffer = 56.
    private static let barChromeWidth: CGFloat = 56
    /// Width consumed by paneDragHandle when sibling panes are present:
    /// icon frame (22) + trailing padding (8) = 30.
    private static let dragHandleWidth: CGFloat = 30
    /// Absolute clamps so chips don't disappear in tiny panes or grow
    /// absurdly wide in huge ones.
    private static let chipMinWidth: CGFloat = 60
    private static let chipMaxWidthCap: CGFloat = 220
    private static let charBudgetMin: Int = 3
    private static let charBudgetMax: Int = 40

    public init(pane: PaneRuntime, tree: SplitTree) {
        self.pane = pane
        self.tree = tree
    }

    private var isPaneFocused: Bool {
        tree.focusedPaneID == pane.id
    }

    private var hasSiblingPanes: Bool {
        tree.visiblePanes.count > 1
    }

    private var chipMaxWidth: CGFloat {
        let count = max(1, CGFloat(pane.tabs.count))
        // When sibling panes are present, paneDragHandle (22pt icon + 8pt trailing
        // padding = 30pt) sits in the same HStack as SlidingTabBar and reduces the
        // width SlidingTabBar actually receives. Without this deduction the inner
        // fixedSize HStack inside SlidingTabBar overflows the pane's allocated width
        // and bleeds visually into the adjacent pane (the merged-tab-bar symptom).
        let reservation = hasSiblingPanes ? Self.dragHandleWidth : 0
        let available = max(0, paneWidth - Self.barChromeWidth - reservation)
        let perChip = (available / count) - 6  // SlidingTabBar's default spacing
        return min(Self.chipMaxWidthCap, max(Self.chipMinWidth, perChip))
    }

    private var charBudget: Int {
        let raw = Int((chipMaxWidth - Self.chipChromeWidth) / Self.approxCharWidth)
        return min(Self.charBudgetMax, max(Self.charBudgetMin, raw))
    }

    private var accentColor: Color {
        themeChrome?.accent ?? Color.accentColor
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SlidingTabBar(
                    items: $pane.tabs,
                    activeID: activeIDBinding,
                    onReorderCommit: nil,
                    onAdd: { pane.addTab(inheritingCWDFrom: pane.activeTab) }
                ) { tab, isActive in
                    BattyTabChip(
                        title: chipTitle(for: tab),
                        isActive: isActive,
                        isPaneFocused: isPaneFocused,
                        hasUnseen: tab.unseenBellCount > 0,
                        onClose: {
                            if let appStore {
                                appStore.requestCloseTab(id: tab.id)
                            } else {
                                pane.removeTab(id: tab.id)
                            }
                        }
                    )
                    .frame(width: chipMaxWidth)
                    .accessibilityIdentifier("tab-chip.\(chipTitle(for: tab))")
                    .contextMenu { tabContextMenu(for: tab) }
                }
                .clipped()
                // .contain marks the tab bar as a container so children stay
                // as discrete accessibility elements with their own ids. Without
                // this, SwiftUI on macOS folds the bar into a leaf and the
                // identifier propagates down to every child Button — chip,
                // close, and "+" all end up with identifier "tab-bar.<uuid>",
                // and `tab-chip.<title>` becomes unfindable.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tab-bar.\(pane.id.uuidString)")

                if hasSiblingPanes {
                    paneDragHandle
                        .padding(.trailing, 8)
                }
                paneEyeButton
            }
            .background(themeChrome?.chromeBackground ?? Color.clear)

            ZStack {
                ForEach(pane.tabs) { tab in
                    TerminalPlaceholderView(
                        tab: tab,
                        isVisible: tab.id == pane.activeTabID && isSessionSelected,
                        paneID: pane.id,
                        isPaneFocused: isPaneFocused
                    )
                        .allowsHitTesting(tab.id == pane.activeTabID)
                        .onChange(of: tab.terminal.bellCount) {
                            if let appStore {
                                appStore.recordBellTick(forTabID: tab.id)
                            } else {
                                tab.recordBellTickIfNeeded()
                            }
                        }
                        .onChange(of: tab.terminal.lastDesktopNotificationAt) {
                            if let appStore {
                                appStore.recordDesktopNotification(forTabID: tab.id)
                            } else {
                                tab.recordDesktopNotificationIfNeeded()
                            }
                        }
                        .modifier(TabRunningCommandObserver(tab: tab))
                        // Deliberately NO .onChange(of: tab.terminal.isFocused)
                        // model write here. libghostty flips isFocused on
                        // existing surfaces during surface creation (#0230
                        // trace), so a model write keyed on that flip cannot
                        // distinguish a user click from churn — it reverted
                        // focus after every split and was the feedback-loop
                        // edge behind #0229's crash. The AppKit-initiated
                        // direction is written by TerminalClickFocusMonitor;
                        // the model-initiated direction by
                        // TerminalSurfaceFocuser. See
                        // docs/swiftui-observation-rules.md.
                        .task(id: tab.id) {
                            tab.terminal.onClose = { [weak appStore, weak pane] processAlive in
                                logger.info("onClose tab=\(tab.id, privacy: .public) processAlive=\(processAlive)")
                                if let appStore {
                                    appStore.closeTab(id: tab.id)
                                } else {
                                    pane?.removeTab(id: tab.id)
                                }
                            }
                            // Drive auto-naming from libghostty's authoritative pwd
                            // signal, not a SwiftUI .onChange over the Combine-backed
                            // workingDirectory — that fired only on incidental
                            // re-renders and left names stuck on the initial cwd (#0227).
                            tab.terminalDelegate.onWorkingDirectoryChange = { [weak appStore] _ in
                                appStore?.handleWorkingDirectoryChange(forTabID: tab.id)
                            }
                            // Initial resolve in case the surface reported its cwd
                            // before this wiring ran (the callback only catches
                            // changes after it's set).
                            appStore?.handleWorkingDirectoryChange(forTabID: tab.id)
                        }
                        .onAppear {
                            guard tab.id == pane.activeTabID, isPaneFocused else { return }
                            TerminalSurfaceFocuser.focusWhenReady(tab: tab)
                        }
                        .onChange(of: pane.activeTabID) { _, newValue in
                            guard tab.id == newValue, isPaneFocused else { return }
                            TerminalSurfaceFocuser.focusWhenReady(tab: tab)
                        }
                        .onChange(of: isPaneFocused) { _, focused in
                            guard focused, tab.id == pane.activeTabID else { return }
                            TerminalSurfaceFocuser.focusWhenReady(tab: tab)
                        }
                }
            }
            .onChange(of: pane.tabs.map(\.bellCount).reduce(0, +)) { _, _ in
                triggerBellFlash()
            }
            .onChange(of: pane.activeTabID) { _, _ in
                appStore?.markActiveTabSeen()
            }
        }
        // Hard-clamp to the size SplitLayout actually allotted this pane
        // *before* .clipped()/.overlay() run. Without this, a tab bar that
        // can't fit its chips at their minimum width (SlidingTabBar's inner
        // fixedSize HStack) makes this VStack report an ideal size wider
        // than the proposal, and everything anchored to that size — the
        // focus-highlight overlay below in particular — draws past the
        // real divider position (#0261). `allottedSize` is nil outside a
        // split (a single unsplit pane), so this is a no-op there.
        //
        // `.topLeading` (not the default `.center`) so any tab-strip
        // overflow clips off the trailing/bottom edges only, preserving
        // the leading (first / active) tabs — this matches the pre-fix
        // leading-anchored `SplitLayout.place(at: minX/minY)` behavior.
        .frame(width: allottedSize?.width, height: allottedSize?.height, alignment: .topLeading)
        // .clipped() constrains the tab bar row to the pane's allocated width.
        // Without it, SlidingTabBar's inner fixedSize HStack can overflow into
        // the adjacent pane when multiple tabs fill the bar, producing the
        // merged-tab-bar appearance from #0253.
        //
        // Note: previously dimmed unfocused panes to 0.7 opacity here.
        // Removed in #0135 round 6 — explicit opacity puts each pane
        // body in an off-screen buffer, and the buffer edges between
        // adjacent .7-alpha siblings composite as thin vertical lines
        // at the pane boundaries. No opacity change here; .clipped() uses
        // a CALayer clip and does not introduce an off-screen buffer.
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(accentColor, lineWidth: 2)
                .opacity((pane.activeTab?.isDragHovering ?? false) ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: pane.activeTab?.isDragHovering ?? false)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(accentColor, lineWidth: 2)
                .opacity(bellFlashOpacity)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(accentColor, lineWidth: 2)
                .opacity(hasSiblingPanes && isPaneFocused ? 0.6 : 0)
                .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
                .allowsHitTesting(false)
        }
        .overlay {
            let state = PaneSwapDragState.shared
            if state.isDragging,
               let sourceID = state.sourcePaneID,
               sourceID != pane.id,
               tree.root.findPane(id: sourceID) != nil {
                PaneSwapDropZone(pane: pane, tree: tree, accentColor: accentColor)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
        .background {
            Color.clear
                .preference(key: PaneFramePreferenceKey.self, value: [pane.id: frameInSession])
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("session")) }) {
                    frameInSession = $0
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                    paneWidth = $0.width
                    paneHeight = $0.height
                }
        }
        .sheet(item: $renamingTab) { tab in
            RenameTabSheet(
                title: $renameDraft,
                placeholder: tab.terminal.title,
                onCommit: {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prior = tab.titleOverride
                    tab.titleOverride = trimmed.isEmpty ? nil : trimmed
                    logger.info("tab-rename: commit tab=\(tab.id, privacy: .public) prior=\(prior ?? "nil", privacy: .public) new=\(tab.titleOverride ?? "nil", privacy: .public)")
                    renamingTab = nil
                },
                onCancel: { renamingTab = nil }
            )
        }
    }

    @ViewBuilder
    private var paneDragHandle: some View {
        // Drag source for #0127 pane swap — handle lives here, on the far-right
        // of the tab bar, rather than on the SlidingTabBar itself because the
        // bar's own per-chip tap/drag gestures win SwiftUI's priority race
        // and the outer .onDrag on the container never fires.
        Image(systemName: "squareshape.split.2x2.dotted.inside")
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Drag to swap with another pane")
            .accessibilityLabel("Pane drag handle")
            .accessibilityIdentifier("pane-drag-handle.\(pane.id.uuidString)")
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDrag {
                logger.info("pane-swap: onDrag closure fired pane=\(pane.id, privacy: .public)")
                PaneSwapDragState.shared.startDrag(from: pane.id)
                return NSItemProvider(object: pane.id.uuidString as NSString)
            } preview: {
                paneDragPreview
            }
    }

    /// Eye button that hides the pane. Disabled when this is the last visible
    /// pane in the session (enforces the ≥1 visible pane invariant). Routes
    /// through AppStateStore → WindowRuntime so TerminalHostStore is always
    /// driven. Event-origin (button tap) — safe per
    /// `docs/swiftui-observation-rules.md`.
    @ViewBuilder
    private var paneEyeButton: some View {
        Button {
            guard let appStore else { return }
            appStore.hidePane(id: pane.id)
        } label: {
            Image(systemName: "eye.slash")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Hide pane")
        .disabled(tree.visiblePanes.count <= 1)
        .padding(.trailing, 4)
        .accessibilityIdentifier("pane-eye-button.\(pane.id.uuidString)")
    }

    @ViewBuilder
    private var paneDragPreview: some View {
        let previewWidth = max(160, min(paneWidth * 0.5, 360))
        let previewHeight = max(96, min(paneHeight * 0.5, 240))
        let title = pane.activeTab.map { chipTitle(for: $0) } ?? "Pane"
        let fill = themeChrome?.chromeBackground ?? Color(nsColor: .windowBackgroundColor)
        let textColor = themeChrome?.chromeForeground ?? Color.primary
        RoundedRectangle(cornerRadius: 6)
            .fill(fill.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accentColor.opacity(0.6), lineWidth: 2)
            )
            .overlay(
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            )
            .frame(width: previewWidth, height: previewHeight)
    }

    @ViewBuilder
    private func tabContextMenu(for tab: TabRuntime) -> some View {
        Button("Rename…") {
            renameDraft = tab.titleOverride ?? ""
            renamingTab = tab
        }
        Button("Reset Title") {
            logger.info("tab-rename: reset tab=\(tab.id, privacy: .public) prior=\(tab.titleOverride ?? "nil", privacy: .public)")
            tab.titleOverride = nil
        }
        .disabled(tab.titleOverride == nil)

        Divider()

        Button("Duplicate Tab") {
            pane.addTab(inheritingCWDFrom: tab)
        }

        Divider()

        Button("Close Tab") {
            if let appStore {
                appStore.requestCloseTab(id: tab.id)
            } else {
                pane.removeTab(id: tab.id)
            }
        }
        Button("Close Other Tabs") {
            if let appStore {
                appStore.requestCloseOtherTabs(paneID: pane.id, keepingTabID: tab.id)
            } else {
                pane.closeOtherTabs(keeping: tab.id)
            }
        }
        .disabled(pane.tabs.count < 2)
    }

    private var activeIDBinding: Binding<UUID?> {
        Binding(
            get: { pane.activeTabID },
            set: { newValue in
                if let newValue { pane.activeTabID = newValue }
                if let appStore {
                    appStore.focusPane(id: pane.id)
                } else {
                    tree.focusedPaneID = pane.id
                }
            }
        )
    }

    static func truncate(_ title: String, limit: Int) -> String {
        guard limit > 1, title.count > limit else { return title }
        let keep = limit - 1
        let head = keep / 2
        let tail = keep - head
        let prefix = title.prefix(head)
        let suffix = title.suffix(tail)
        return "\(prefix)…\(suffix)"
    }

    private func triggerBellFlash() {
        bellFlashOpacity = 1
        withAnimation(.easeOut(duration: 1.0)) {
            bellFlashOpacity = 0
        }
    }

    private func chipTitle(for tab: TabRuntime) -> String {
        TabTitleFormatter.chipTitle(for: tab)
    }
}

/// Transparent drop zone that appears over non-source panes during a pane-swap
/// drag. Only exists while a drag is active, so the terminal NSView receives
/// file drops unimpeded in the normal (no-drag) state.
///
/// `.onDrop` is safe here because this view only exists when a pane-swap drag
/// is already in progress — the user is dragging a pane handle, not a Finder
/// file, so blocking other drop types is acceptable for the duration.
private struct PaneSwapDropZone: View {
    let pane: PaneRuntime
    @Bindable var tree: SplitTree
    let accentColor: Color
    @State private var isTargeted = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .accessibilityIdentifier("pane-drop-zone.\(pane.id.uuidString)")
            .onAppear {
                logger.debug("pane-swap: drop-zone mounted pane=\(pane.id, privacy: .public)")
            }
            .onDisappear {
                logger.debug("pane-swap: drop-zone unmounted pane=\(pane.id, privacy: .public)")
            }
            .onDrop(of: [.plainText], isTargeted: $isTargeted) { providers in
                defer { PaneSwapDragState.shared.endDrag(trigger: .dropDefer) }
                let targetID = pane.id
                let providerCount = providers.count
                providers.first?.loadDataRepresentation(
                    forTypeIdentifier: UTType.plainText.identifier
                ) { data, _ in
                    guard let data else {
                        logger.notice("pane-swap: drop on=\(targetID, privacy: .public) providers=\(providerCount, privacy: .public) load=failed")
                        return
                    }
                    guard let idString = String(data: data, encoding: .utf8) else {
                        logger.notice("pane-swap: drop on=\(targetID, privacy: .public) providers=\(providerCount, privacy: .public) load=not-utf8")
                        return
                    }
                    guard let sourceID = UUID(uuidString: idString) else {
                        logger.notice("pane-swap: drop on=\(targetID, privacy: .public) providers=\(providerCount, privacy: .public) load=not-a-uuid")
                        return
                    }
                    guard sourceID != targetID else {
                        logger.info("pane-swap: drop on=\(targetID, privacy: .public) source=\(sourceID, privacy: .public) swap=false reason=self-drop")
                        return
                    }
                    DispatchQueue.main.async {
                        logger.info("pane-swap: swap source=\(sourceID, privacy: .public) target=\(targetID, privacy: .public)")
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            tree.swapPanes(id: sourceID, with: targetID)
                        }
                    }
                }
                return true
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(accentColor, lineWidth: 3)
                    .opacity(isTargeted ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: isTargeted)
                    .allowsHitTesting(false)
            }
    }
}

/// Observes the terminal's OSC 2 title and OSC 133 D command-finished
/// markers and keeps ``TabRuntime.runningCommandDisplayName`` in sync.
///
/// Extracted from ``PaneView`` because adding both `.onChange` modifiers
/// inline pushes the surrounding `ViewBuilder` past the SwiftUI
/// type-checker's complexity budget.
private struct TabRunningCommandObserver: ViewModifier {
    let tab: TabRuntime

    func body(content: Content) -> some View {
        content
            .onChange(of: tab.terminal.title) {
                tab.refreshRunningCommandFromTitle()
            }
            .onChange(of: tab.terminal.lastCommandDurationNanos) {
                tab.recordCommandFinishedIfNeeded()
            }
    }
}
