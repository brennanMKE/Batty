// SessionColorPickerView.swift

import SwiftUI

/// Pure, testable cursor arithmetic for `SessionColorPickerView`'s swatch
/// grid — 10 swatches (5 columns × 2 rows) plus a full-width "Automatic"
/// row below them. Lifted out of the view (#0336 review round 2) so the
/// exact math that shipped broken in review round 1 (M2: modulo-11
/// arithmetic across a 5-wide grid, which doesn't preserve columns on
/// wrap) has automated coverage instead of resting on a reviewer's
/// hand-trace — `SessionColorGridCursorTests` exercises all 44
/// transitions (←/→/↑/↓ from each of the 10 swatches and from Automatic).
struct SessionColorGridCursor: Equatable, Sendable {
    enum Position: Equatable, Sendable {
        case swatch(Int)
        case automatic
    }

    static let columns = 5
    static let paletteCount = SessionColor.allCases.count
    static let rows = (paletteCount + columns - 1) / columns

    let position: Position

    init(_ position: Position) {
        self.position = position
    }

    private static func row(for index: Int) -> Int { index / columns }
    private static func column(for index: Int) -> Int { index % columns }

    /// Horizontal move (`dx`: -1 left, +1 right). Column ± `dx`, clamped to
    /// `0..<columns`; row is always preserved. "Automatic" has no columns
    /// and never moves horizontally.
    func moved(dx: Int) -> SessionColorGridCursor {
        switch position {
        case .swatch(let index):
            let newColumn = Self.column(for: index) + dx
            guard (0..<Self.columns).contains(newColumn) else { return self }
            let candidate = Self.row(for: index) * Self.columns + newColumn
            // Forward-safety for a ragged last row on a future palette size
            // not divisible by `columns` — unreachable at 10/5 today.
            guard candidate < Self.paletteCount else { return self }
            return SessionColorGridCursor(.swatch(candidate))
        case .automatic:
            return self
        }
    }

    /// Vertical move (`dy`: -1 up, +1 down). Clamps at every edge — a move
    /// past the top or bottom of its section is a no-op — rather than
    /// wrapping. Down from the last swatch row lands on the full-width
    /// "Automatic" row; Up from "Automatic" returns to that row's column 0
    /// (index 5), since "Automatic" itself has no column to preserve.
    func moved(dy: Int) -> SessionColorGridCursor {
        switch position {
        case .swatch(let index):
            let targetRow = Self.row(for: index) + dy
            if targetRow < 0 {
                return self
            }
            if targetRow >= Self.rows {
                return SessionColorGridCursor(.automatic)
            }
            let candidate = targetRow * Self.columns + Self.column(for: index)
            // Forward-safety for a ragged last row — unreachable at 10/5.
            guard candidate < Self.paletteCount else {
                return SessionColorGridCursor(.automatic)
            }
            return SessionColorGridCursor(.swatch(candidate))
        case .automatic:
            guard dy < 0 else { return self }
            let lastRow = Self.rows - 1
            let candidate = min(lastRow * Self.columns, Self.paletteCount - 1)
            return SessionColorGridCursor(.swatch(candidate))
        }
    }
}

/// Swatch-grid picker for a Session's explicit color (#0336), presented as
/// a sheet from `SessionSidebarView` the same way `SessionThemeSelectorView`
/// is — keyed by a `@State` session id, never attached to the context
/// menu's own view (the menu's host view goes away when the menu
/// dismisses). Takes primitive values captured when the sheet opens rather
/// than the whole `SessionRuntime`, so this view never observes unrelated
/// Session state.
struct SessionColorPickerView: View {
    @Binding var isPresented: Bool
    let windowRuntime: WindowRuntime
    let sessionID: UUID
    let currentIndex: Int
    let isOverride: Bool

    /// Where the keyboard cursor (and the ring/click target) currently
    /// sits. Always seeded to the swatch matching the Session's current
    /// color — never to `.automatic` — so the ring is visible the instant
    /// the sheet opens even when that color came from the automatic
    /// assigner (review round 1, M1).
    @State private var cursor: SessionColorGridCursor
    /// Whether the Session is currently under automatic assigner control,
    /// for the "Automatic" entry's checkmark. A plain `let`, not `@State`:
    /// every write path in this view (`commit(_:)`) dismisses the sheet in
    /// the same call, so no frame of this view ever renders with a value
    /// other than `!isOverride` — there is nothing here for this to
    /// observe changing (review round 2).
    private let isAutomatic: Bool
    @FocusState private var isFocused: Bool

    init(isPresented: Binding<Bool>, windowRuntime: WindowRuntime, sessionID: UUID, currentIndex: Int, isOverride: Bool) {
        self._isPresented = isPresented
        self.windowRuntime = windowRuntime
        self.sessionID = sessionID
        self.currentIndex = currentIndex
        self.isOverride = isOverride
        self._cursor = State(initialValue: SessionColorGridCursor(.swatch(currentIndex)))
        self.isAutomatic = !isOverride
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: SessionColorGridCursor.columns)
    }

    private var statusText: String {
        let name = (SessionColor(rawValue: currentIndex) ?? .blue).displayName
        return isOverride
            ? String(localized: "\(name), chosen by you", comment: "Session color picker status line")
            : String(localized: "\(name), automatically assigned", comment: "Session color picker status line")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Session Color")
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(Array(SessionColor.allCases.enumerated()), id: \.offset) { index, swatchColor in
                    Button {
                        cursor = SessionColorGridCursor(.swatch(index))
                        commit(.swatch(index))
                    } label: {
                        SessionColorSwatch(
                            color: swatchColor.color,
                            isSelected: cursor.position == .swatch(index)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(swatchColor.displayName))
                    .accessibilityAddTraits(cursor.position == .swatch(index) ? .isSelected : [])
                }
            }

            Divider()

            Button {
                cursor = SessionColorGridCursor(.automatic)
                commit(.automatic)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isAutomatic ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isAutomatic ? Color.accentColor : Color.secondary)
                    Text("Automatic")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(cursor.position == .automatic ? Color.accentColor.opacity(0.15) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Automatic"))
            .accessibilityAddTraits(isAutomatic ? .isSelected : [])

            HStack {
                Spacer()
                Text("Esc to cancel \u{00B7} Return to set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 260)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { cursor = cursor.moved(dx: -1); return .handled }
        .onKeyPress(.rightArrow) { cursor = cursor.moved(dx: 1); return .handled }
        .onKeyPress(.upArrow) { cursor = cursor.moved(dy: -1); return .handled }
        .onKeyPress(.downArrow) { cursor = cursor.moved(dy: 1); return .handled }
        .onKeyPress(.return) { commit(cursor.position); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
    }

    private func commit(_ target: SessionColorGridCursor.Position) {
        switch target {
        case .automatic:
            windowRuntime.resetSessionColor(id: sessionID)
        case .swatch(let index):
            windowRuntime.setSessionColor(id: sessionID, to: index)
        }
        isPresented = false
    }

    private func cancel() {
        isPresented = false
    }
}

private struct SessionColorSwatch: View {
    let color: Color
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
            if isSelected {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: 2)
                    .frame(width: 34, height: 34)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
}
