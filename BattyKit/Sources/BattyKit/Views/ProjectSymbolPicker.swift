// ProjectSymbolPicker.swift

import SwiftUI

/// The Project Editor's Symbol field: a button showing the draft's symbol
/// that opens a 6x6 grid of the catalog in a popover.
///
/// The popover window does not reliably become key, so keyboard focus can stay
/// on this field while the grid is up. The field therefore owns the cursor and
/// handles the arrows, Return, Space and Escape itself while the popover is
/// open; the grid handles the same keys when it does receive them.
struct ProjectSymbolPicker: View {
    let model: ProjectEditorViewModel
    @State private var isPresented = false
    @State private var cursor = ProjectSymbolGridCursor(ProjectSymbol.default)
    @State private var returnFocusOnClose = false
    @FocusState private var isFieldFocused: Bool

    private var selected: ProjectSymbol { model.draft?.symbol ?? .default }
    private var color: Color { (model.draft?.color ?? .blue).color }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                open()
            } label: {
                Image(systemName: selected.resolvedSystemName)
                    .foregroundStyle(color)
                    .frame(width: 26, height: 22)
            }
            .help(selected.displayName)
            .accessibilityLabel(Text("Symbol"))
            .accessibilityValue(Text(selected.displayName))
            .accessibilityIdentifier("project-editor.symbol")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ProjectSymbolGrid(
                    selected: selected,
                    color: color,
                    cursor: $cursor,
                    choose: choose,
                    cancel: cancel
                )
            }
        }
        .padding(2)
        .overlay {
            if isFieldFocused {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFieldFocused)
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.escape) {
            guard isPresented else { return .ignored }
            cancel()
            return .handled
        }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onChange(of: isPresented) { _, presented in
            guard !presented else { return }
            if returnFocusOnClose { isFieldFocused = true }
            returnFocusOnClose = false
        }
    }

    private func open() {
        cursor = ProjectSymbolGridCursor(selected)
        isPresented = true
    }

    private func choose(_ symbol: ProjectSymbol) {
        model.setSymbol(symbol)
        returnFocusOnClose = true
        isPresented = false
    }

    private func cancel() {
        returnFocusOnClose = true
        isPresented = false
    }

    private func move(_ direction: ProjectSymbolGridCursor.Direction) -> KeyPress.Result {
        guard isPresented else { return .ignored }
        cursor = cursor.moved(direction)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        if isPresented {
            choose(cursor.symbol)
        } else {
            open()
        }
        return .handled
    }
}

private struct ProjectSymbolGrid: View {
    let selected: ProjectSymbol
    let color: Color
    @Binding var cursor: ProjectSymbolGridCursor
    let choose: (ProjectSymbol) -> Void
    let cancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: ProjectSymbolGridCursor.columns), spacing: 4) {
            ForEach(ProjectSymbol.allCases, id: \.rawValue) { symbol in
                Button {
                    choose(symbol)
                } label: {
                    Image(systemName: symbol.resolvedSystemName)
                        .font(.system(size: 16))
                        .foregroundStyle(color)
                        .frame(width: 34, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(cursor.symbol == symbol ? 0.12 : 0))
                        )
                        .overlay {
                            if symbol == selected {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(symbol.displayName)
                .accessibilityLabel(Text(symbol.displayName))
                .accessibilityAddTraits(symbol == selected ? .isSelected : [])
                .accessibilityIdentifier("project-editor.symbol.\(symbol.rawValue)")
            }
        }
        .padding(12)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { cursor = cursor.moved(.left); return .handled }
        .onKeyPress(.rightArrow) { cursor = cursor.moved(.right); return .handled }
        .onKeyPress(.upArrow) { cursor = cursor.moved(.up); return .handled }
        .onKeyPress(.downArrow) { cursor = cursor.moved(.down); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(.return) { choose(cursor.symbol); return .handled }
        .onKeyPress(.space) { choose(cursor.symbol); return .handled }
    }
}
