// LayoutPickerView.swift

import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleLayoutPicker = Notification.Name("co.sstools.Batty.toggleLayoutPicker")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "LayoutPickerView")

struct LayoutPickerView: View {
    @Binding var isPresented: Bool
    let windowRuntime: WindowRuntime

    @Environment(\.themeChrome) private var themeChrome
    @State private var selectedIndex = 0
    @FocusState private var gridFocused: Bool

    private let layouts = PaneLayout.allCases

    // Number of columns in the grid (kept in sync with the adaptive minimum below).
    // Used for arrow-key navigation: left/right move by 1, up/down move by columnCount.
    private let columnCount = 4

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose a Layout")
                    .font(.headline)
                Spacer()
                Text("Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 160))],
                    spacing: 16
                ) {
                    ForEach(Array(layouts.enumerated()), id: \.element.id) { idx, layout in
                        VStack(spacing: 4) {
                            LayoutThumbnailView(
                                layout: layout,
                                isSelected: idx == selectedIndex,
                                themeChrome: themeChrome
                            )
                            Text(layout.name)
                                .font(.caption)
                                .foregroundStyle(idx == selectedIndex ? .primary : .secondary)
                                .multilineTextAlignment(.center)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = idx
                            activate()
                        }
                    }
                }
                .padding(16)
            }

            // Invisible focusable view that captures arrow-key / Return / Escape
            // events for the grid. The grid itself isn't directly focusable in
            // SwiftUI, so we overlay a zero-size rectangle that holds focus.
            Rectangle()
                .opacity(0)
                .frame(width: 0, height: 0)
                .focused($gridFocused)
                .onKeyPress(.leftArrow)  { moveSelection(-1);           return .handled }
                .onKeyPress(.rightArrow) { moveSelection(1);            return .handled }
                .onKeyPress(.upArrow)    { moveSelection(-columnCount); return .handled }
                .onKeyPress(.downArrow)  { moveSelection(columnCount);  return .handled }
                .onKeyPress(.return)     { activate();                   return .handled }
                .onKeyPress(.escape)     { isPresented = false;          return .handled }
        }
        .frame(width: 600, height: 420)
        .background(.regularMaterial)
        .onAppear { gridFocused = true }
    }

    private func moveSelection(_ delta: Int) {
        let count = layouts.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activate() {
        let layout = layouts[selectedIndex]
        logger.info("layout picker applying \(layout.rawValue, privacy: .public)")
        if let tree = windowRuntime.selectedSession?.tree {
            layout.apply(to: tree)
        }
        isPresented = false
    }
}
