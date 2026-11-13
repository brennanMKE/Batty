// ProjectSymbolPicker.swift

import AppKit
import SwiftUI

/// The Project Editor's Symbol field: a button showing the draft's symbol
/// that opens a sheet with a name filter and a grid of SF Symbols.
///
/// Filter text, the cursor and presentation are view-local state. The draft
/// is written only from `choose`, an event handler.
struct ProjectSymbolPicker: View {
    let model: ProjectEditorViewModel
    @State private var isPresented = false
    @State private var returnFocusOnClose = false
    @FocusState private var isFieldFocused: Bool

    private var selectedName: String {
        guard let draft = model.draft else { return ProjectSymbol.default.systemName }
        return draft.customSymbolName ?? draft.symbol.systemName
    }
    private var displayName: String {
        guard let draft = model.draft else { return ProjectSymbol.default.displayName }
        return ProjectAppearance.displayName(symbol: draft.symbol, customName: draft.customSymbolName)
    }
    private var systemName: String {
        guard let draft = model.draft else { return ProjectSymbol.default.resolvedSystemName }
        return ProjectAppearance.systemName(symbol: draft.symbol, customName: draft.customSymbolName)
    }
    private var color: Color {
        guard let draft = model.draft else { return SessionColor.blue.color }
        return ProjectAppearance.color(palette: draft.color, customHex: draft.customColorHex)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isPresented = true
            } label: {
                Image(systemName: systemName)
                    .foregroundStyle(color)
                    .frame(width: 26, height: 22)
            }
            .focusable(false)
            .help(displayName)
            .accessibilityLabel(Text("Symbol"))
            .accessibilityValue(Text(displayName))
            .accessibilityIdentifier("project-editor.symbol")
            .sheet(isPresented: $isPresented, onDismiss: returnFocus) {
                ProjectSymbolSheet(selectedName: selectedName, color: color, choose: choose, cancel: cancel)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Symbol"))
        .onKeyPress(.return) { isPresented = true; return .handled }
        .onKeyPress(.space) { isPresented = true; return .handled }
    }

    private func returnFocus() {
        if returnFocusOnClose { isFieldFocused = true }
        returnFocusOnClose = false
    }

    private func choose(_ name: String) {
        model.setSymbolName(name)
        returnFocusOnClose = true
        isPresented = false
    }

    private func cancel() {
        returnFocusOnClose = true
        isPresented = false
    }
}

private struct ProjectSymbolSheet: View {
    let selectedName: String
    let color: Color
    let choose: (String) -> Void
    let cancel: () -> Void

    @State private var catalog: SFSymbolCatalog?
    @State private var filter = ""
    @State private var names: [String] = []
    @State private var suggestedCount = 0
    @State private var cursor = ProjectSymbolListCursor(0, count: 0)
    @FocusState private var filterFocused: Bool
    @State private var returnMonitor = SheetReturnKeyMonitor()

    private static let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: ProjectSymbolListCursor.columns)

    var body: some View {
        VStack(spacing: 10) {
            TextField("Filter by name", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .accessibilityIdentifier("project-editor.symbol.filter")
                .onKeyPress(.upArrow) { cursor = cursor.moved(.up); return .handled }
                .onKeyPress(.downArrow) { cursor = cursor.moved(.down); return .handled }
                .onKeyPress(.leftArrow) { filter.isEmpty ? move(.left) : .ignored }
                .onKeyPress(.rightArrow) { filter.isEmpty ? move(.right) : .ignored }

            if catalog == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if names.isEmpty {
                Text("No matching symbols")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if suggestedCount > 0 { header("Suggested") }
                            LazyVGrid(columns: Self.columns, spacing: 4) {
                                ForEach(names.indices.prefix(suggestedCount), id: \.self) { cell(names[$0], index: $0) }
                            }
                            if suggestedCount > 0 { header("All Symbols") }
                            LazyVGrid(columns: Self.columns, spacing: 4) {
                                ForEach(names.indices.dropFirst(suggestedCount), id: \.self) { cell(names[$0], index: $0) }
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: cursor) { _, new in
                        syncSelection()
                        guard names.indices.contains(new.index) else { return }
                        proxy.scrollTo(new.index)
                    }
                }
            }

            HStack {
                Text(names.indices.contains(cursor.index) ? names[cursor.index] : " ")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project-editor.symbol.cancel")
                Button("Choose", action: chooseCursor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!names.indices.contains(cursor.index))
                    .accessibilityIdentifier("project-editor.symbol.choose")
            }
        }
        .padding(14)
        .frame(width: 400, height: 420)
        .onAppear {
            filterFocused = true
            returnMonitor.start(choose: choose)
        }
        .onDisappear { returnMonitor.stop() }
        .task {
            catalog = SFSymbolCatalog.shared
            reload()
        }
        .onChange(of: filter) { reload() }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ name: String, index: Int) -> some View {
        let legacy = ProjectAppearance.legacySymbol(forSystemName: name)
        let label = legacy?.displayName ?? name
        return Button {
            choose(name)
        } label: {
            Image(systemName: name)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(cursor.index == index ? 0.12 : 0))
                )
                .overlay {
                    if name == selectedName {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(name)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(name == selectedName ? .isSelected : [])
        .accessibilityIdentifier(
            index < suggestedCount && legacy != nil
                ? "project-editor.symbol.\(legacy!.rawValue)"
                : "project-editor.symbol.name.\(name)"
        )
    }

    private func reload() {
        guard let catalog else { return }
        let listing = catalog.listing(for: filter)
        names = listing.names
        suggestedCount = listing.suggestedCount
        let start = filter.trimmingCharacters(in: .whitespaces).isEmpty ? (names.firstIndex(of: selectedName) ?? 0) : 0
        cursor = ProjectSymbolListCursor(start, count: names.count)
        syncSelection()
    }

    private func syncSelection() {
        returnMonitor.selection = names.indices.contains(cursor.index) ? names[cursor.index] : nil
    }

    private func move(_ direction: ProjectSymbolListCursor.Direction) -> KeyPress.Result {
        cursor = cursor.moved(direction)
        return .handled
    }

    private func chooseCursor() {
        guard names.indices.contains(cursor.index) else { return }
        choose(names[cursor.index])
    }
}

/// Chooses the highlighted symbol on a plain Return while the sheet is up.
/// The filter's field editor and the sheet's default button do not deliver
/// a synthesized Return to SwiftUI (`onSubmit`, `onKeyPress` and a default
/// action all stayed silent in the UI test VM), so the key is taken from a
/// local event monitor, which does see it. Holds the highlighted name as
/// plain state because the monitor outlives any one view update.
final class SheetReturnKeyMonitor {
    var selection: String?
    private var token: Any?

    func start(choose: @escaping (String) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isChooseKey(event, isSheet: event.window?.isSheet == true, sheetParentIdentifier: event.window?.sheetParent?.identifier?.rawValue),
                  let name = self?.selection
            else { return event }
            self?.stop()
            choose(name)
            return nil
        }
    }

    /// A plain Return, in a sheet whose direct parent is the Project Editor
    /// window. The Editor is not modal, so a sheet in another window (Rename
    /// Session, the Command Palette) must keep its own Return.
    static func isChooseKey(_ event: NSEvent, isSheet: Bool, sheetParentIdentifier: String?) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && isSheet
            && sheetParentIdentifier == ProjectEditorWindowController.windowIdentifier
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
