// GridSelection.swift

import Observation

/// A grid's highlighted cell, held outside the grid's view so only the cells
/// that compare against it, and not the grid, are invalidated when it moves:
/// re-evaluating the grids above a scrolled viewport can move the visible rows.
@MainActor
@Observable
final class GridSelection<ID: Hashable> {
    private(set) var id: ID?

    func select(_ id: ID?) {
        guard self.id != id else { return }
        BackgroundImagesDiagnostics.shared.record("selection change")
        self.id = id
    }
}
