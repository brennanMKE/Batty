// PaneView.swift

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
private final class PaneSwapDragState {
    static let shared = PaneSwapDragState()
    private(set) var isDragging = false
    private(set) var sourcePaneID: UUID? = nil
    private var monitor: Any? = nil
    private var fallbackTimer: Timer? = nil

    func startDrag(from paneID: UUID) {
        endDrag()
        isDragging = true
        sourcePaneID = paneID
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { self?.endDrag() }
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.endDrag() }
        }
    }

    func endDrag() {
        isDragging = false
        sourcePaneID = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}

public struct PaneView: View {
    @Bindable public var pane: PaneRuntime
    @Bindable public var tree: SplitTree
    @Environment(\.appStateStore) private var appStore
    @Environment(\.isSelectedSession) private var isSessionSelected
    @Environment(\.themeChrome) private var themeChrome
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
    /// Per-bar overhead (horizontal padding + "+" button + spacing).
    private static let barChromeWidth: CGFloat = 56
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
        tree.allPanes.count > 1
    }

    private var chipMaxWidth: CGFloat {
        let count = max(1, CGFloat(pane.tabs.count))
        let available = max(0, paneWidth - Self.barChromeWidth)
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
                .accessibilityIdentifier("tab-bar.\(pane.id.uuidString)")

                if hasSiblingPanes {
                    paneDragHandle
                        .padding(.trailing, 8)
                }
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
                        .onChange(of: tab.terminal.workingDirectory) {
                            appStore?.handleWorkingDirectoryChange(forTabID: tab.id)
                        }
                        .modifier(TabRunningCommandObserver(tab: tab))
                        .onChange(of: tab.terminal.isFocused) { _, isFocused in
                            guard isFocused else { return }
                            if let appStore {
                                appStore.focusPane(id: pane.id)
                            } else {
                                tree.focusedPaneID = pane.id
                            }
                        }
                        .task(id: tab.id) {
                            tab.terminal.onClose = { [weak appStore, weak pane] _ in
                                if let appStore {
                                    appStore.closeTab(id: tab.id)
                                } else {
                                    pane?.removeTab(id: tab.id)
                                }
                            }
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
                if state.isDragging, state.sourcePaneID != pane.id {
                    PaneSwapDropZone(pane: pane, tree: tree, accentColor: accentColor)
                }
            }
            // Note: previously dimmed unfocused panes to 0.7 opacity here.
            // Removed in #0135 round 6 — explicit opacity puts each pane
            // body in an off-screen buffer, and the buffer edges between
            // adjacent .7-alpha siblings composite as thin vertical lines
            // at the pane boundaries (the line artifact the user reported
            // through rounds 3–5). Focus is still indicated by the accent
            // border overlay above.
            .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
            .onChange(of: pane.tabs.map(\.bellCount).reduce(0, +)) { _, _ in
                triggerBellFlash()
            }
            .onChange(of: pane.activeTabID) { _, _ in
                appStore?.markActiveTabSeen()
            }
        }
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
                    tab.titleOverride = trimmed.isEmpty ? nil : trimmed
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
        Image(systemName: "rectangle.grid.1x2")
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
                PaneSwapDragState.shared.startDrag(from: pane.id)
                return NSItemProvider(object: pane.id.uuidString as NSString)
            } preview: {
                paneDragPreview
            }
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
            .onDrop(of: [.plainText], isTargeted: $isTargeted) { providers in
                defer { PaneSwapDragState.shared.endDrag() }
                providers.first?.loadDataRepresentation(
                    forTypeIdentifier: UTType.plainText.identifier
                ) { data, _ in
                    guard let data,
                          let idString = String(data: data, encoding: .utf8),
                          let sourceID = UUID(uuidString: idString),
                          sourceID != pane.id
                    else { return }
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            tree.swapPanes(id: sourceID, with: pane.id)
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
