// PaneView.swift

import SwiftUI

public struct PaneView: View {
    @Bindable public var pane: PaneRuntime
    @Bindable public var tree: SplitTree
    public var paneDrag: PaneDragController?
    @Environment(\.appStateStore) private var appStore
    @Environment(\.isSelectedSession) private var isSessionSelected
    @State private var bellFlashOpacity: Double = 0
    @State private var renamingTab: TabRuntime?
    @State private var renameDraft: String = ""
    @State private var paneWidth: CGFloat = 0
    @State private var paneSize: CGSize = .zero

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

    public init(pane: PaneRuntime, tree: SplitTree, paneDrag: PaneDragController? = nil) {
        self.pane = pane
        self.tree = tree
        self.paneDrag = paneDrag
    }

    private var isPaneFocused: Bool {
        tree.focusedPaneID == pane.id
    }

    private var hasSiblingPanes: Bool {
        tree.allPanes.count > 1
    }

    private var isBeingDragged: Bool {
        paneDrag?.draggedPaneID == pane.id
    }

    private var isPaneDropTarget: Bool {
        guard let paneDrag, paneDrag.isDragging else { return false }
        return paneDrag.dropTargetPaneID == pane.id
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

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if hasSiblingPanes {
                    paneDragHandle
                }
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
            }

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
                            TerminalSurfaceFocuser.focusWhenReady(terminal: tab.terminal)
                        }
                        .onChange(of: pane.activeTabID) { _, newValue in
                            guard tab.id == newValue, isPaneFocused else { return }
                            TerminalSurfaceFocuser.focusWhenReady(terminal: tab.terminal)
                        }
                        .onChange(of: isPaneFocused) { _, focused in
                            guard focused, tab.id == pane.activeTabID else { return }
                            TerminalSurfaceFocuser.focusWhenReady(terminal: tab.terminal)
                        }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity((pane.activeTab?.isDragHovering ?? false) ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: pane.activeTab?.isDragHovering ?? false)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(bellFlashOpacity)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(hasSiblingPanes && isPaneFocused ? 0.6 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    )
                    .opacity(isPaneDropTarget ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isPaneDropTarget)
                    .allowsHitTesting(false)
            }
            .opacity(isBeingDragged ? 0.35 : (hasSiblingPanes && !isPaneFocused ? 0.7 : 1))
            .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
            .animation(.easeOut(duration: 0.12), value: isBeingDragged)
            .onChange(of: pane.tabs.map(\.bellCount).reduce(0, +)) { _, _ in
                triggerBellFlash()
            }
            .onChange(of: pane.activeTabID) { _, _ in
                appStore?.markActiveTabSeen()
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: PaneFramePreferenceKey.self,
                        value: [pane.id: geo.frame(in: .named("session"))]
                    )
                    .onAppear {
                        paneWidth = geo.size.width
                        paneSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newValue in
                        paneWidth = newValue.width
                        paneSize = newValue
                    }
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
        Image(systemName: "rectangle.grid.1x2")
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
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
            .gesture(paneDragGesture)
    }

    private var paneDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("session"))
            .onChanged { value in
                guard let paneDrag else { return }
                if paneDrag.draggedPaneID == nil {
                    appStore?.focusPane(id: pane.id)
                    paneDrag.begin(
                        paneID: pane.id,
                        paneSize: paneSize,
                        cursor: value.location
                    )
                }
                paneDrag.update(cursor: value.location, frames: sessionPaneFrames)
            }
            .onEnded { _ in
                guard let paneDrag else { return }
                if let (draggedID, targetID) = paneDrag.end() {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        _ = tree.swapPanes(draggedID, targetID)
                    }
                    appStore?.focusPane(id: draggedID)
                }
            }
    }

    private var sessionPaneFrames: [UUID: CGRect] {
        guard let appStore, let session = appStore.sessions.first(where: { $0.tree === tree }) else {
            return [:]
        }
        return session.paneFrames.frames
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
