// PaneView.swift

import SwiftUI
import UniformTypeIdentifiers

public struct PaneView: View {
    @Bindable public var pane: PaneRuntime
    @Bindable public var tree: SplitTree
    @Environment(\.appStateStore) private var appStore
    @State private var isDragHovering: Bool = false
    @State private var bellFlashOpacity: Double = 0
    @State private var renamingTab: TabRuntime?
    @State private var renameDraft: String = ""
    @State private var paneWidth: CGFloat = 0

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

    public var body: some View {
        VStack(spacing: 0) {
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
                            appStore.closeTab(id: tab.id)
                        } else {
                            pane.removeTab(id: tab.id)
                        }
                    }
                )
                .frame(width: chipMaxWidth)
                .contextMenu { tabContextMenu(for: tab) }
            }
            .clipped()

            ZStack {
                ForEach(pane.tabs) { tab in
                    TerminalSurfaceView(context: tab.terminal)
                        .opacity(tab.id == pane.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == pane.activeTabID)
                        .onDrop(
                            of: [.fileURL],
                            isTargeted: tab.id == pane.activeTabID ? $isDragHovering : .constant(false)
                        ) { providers in
                            guard tab.id == pane.activeTabID else { return false }
                            return Self.handleFileDrop(providers, into: tab.terminal)
                        }
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
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isDragHovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isDragHovering)
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
            .opacity(hasSiblingPanes && !isPaneFocused ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.12), value: isPaneFocused)
            .onChange(of: pane.tabs.map(\.bellCount).reduce(0, +)) { _, _ in
                triggerBellFlash()
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: PaneFramePreferenceKey.self,
                        value: [pane.id: geo.frame(in: .named("session"))]
                    )
                    .onAppear { paneWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in
                        paneWidth = newValue
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
                appStore.closeTab(id: tab.id)
            } else {
                pane.removeTab(id: tab.id)
            }
        }
        Button("Close Other Tabs") {
            pane.closeOtherTabs(keeping: tab.id)
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

    static func handleFileDrop(
        _ providers: [NSItemProvider],
        into terminal: TerminalViewState
    ) -> Bool {
        let fileURLType = UTType.fileURL.identifier
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        guard !candidates.isEmpty else { return false }

        Task { @MainActor in
            let ordered = await loadFilePaths(from: candidates, fileURLType: fileURLType)
            guard !ordered.isEmpty else { return }
            terminal.send(ShellQuote.joinPaths(ordered))
        }
        return true
    }

    private static func loadFilePaths(
        from providers: [NSItemProvider],
        fileURLType: String
    ) async -> [String] {
        var paths: [String] = []
        for provider in providers {
            if let path = await loadFilePath(from: provider, type: fileURLType) {
                paths.append(path)
            }
        }
        return paths
    }

    private static func loadFilePath(
        from provider: NSItemProvider,
        type fileURLType: String
    ) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let direct as URL:
                    url = direct
                case let data as Data:
                    url = URL(dataRepresentation: data, relativeTo: nil)
                case let path as String:
                    url = URL(string: path)
                default:
                    url = nil
                }
                let resolved = (url?.isFileURL == true) ? url?.path : nil
                continuation.resume(returning: resolved)
            }
        }
    }

    private func chipTitle(for tab: TabRuntime) -> String {
        TabTitleFormatter.chipTitle(for: tab)
    }
}
