// PaneView.swift

import SwiftUI

public struct PaneView: View {
    @Bindable public var pane: PaneRuntime

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
                }
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
