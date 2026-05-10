// PaneView.swift

import SwiftUI
import UniformTypeIdentifiers

public struct PaneView: View {
    @Bindable public var pane: PaneRuntime
    @State private var isDragHovering: Bool = false

    public init(pane: PaneRuntime) {
        self.pane = pane
    }

    public var body: some View {
        VStack(spacing: 0) {
            SlidingTabBar(
                items: $pane.tabs,
                activeID: activeIDBinding,
                onReorderCommit: nil,
                onAdd: { pane.addTab(inheritingCWDFrom: pane.activeTab) }
            ) { tab, isActive in
                DefaultTabChip(
                    title: chipTitle(for: tab),
                    isActive: isActive,
                    hasUnseen: false,
                    onClose: pane.tabs.count > 1 ? { pane.removeTab(id: tab.id) } : nil
                )
            }

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
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isDragHovering ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isDragHovering)
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: PaneFramePreferenceKey.self,
                    value: [pane.id: geo.frame(in: .named("session"))]
                )
            }
        }
    }

    private var activeIDBinding: Binding<UUID?> {
        Binding(
            get: { pane.activeTabID },
            set: { newValue in
                if let newValue { pane.activeTabID = newValue }
            }
        )
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
        if let override = tab.titleOverride, !override.isEmpty { return override }
        let live = tab.terminal.title
        if !live.isEmpty { return live }
        if let cwd = tab.terminal.workingDirectory, !cwd.isEmpty {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty, basename != "/" { return basename }
        }
        return "Tab"
    }
}
