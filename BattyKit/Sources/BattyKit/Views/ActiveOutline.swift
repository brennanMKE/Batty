// ActiveOutline.swift

import SwiftUI

/// "This is the active item" outline for the Theme Selector's active-Theme
/// card (`ThemeCard`). Originated as the Pane focus highlight (`#0052`) and
/// was extracted (`#0363`) so the card could reuse the same visual; Pane
/// outlines have since moved to `PaneAccentStroke` (`#0339`), so `ThemeCard`
/// is the only caller. Visual contract: 2pt `strokeBorder`, 0.6 opacity when
/// active, 0.12s ease-in-out fade keyed on `isActive`, hit-testing disabled
/// so the outline never intercepts clicks/drags meant for the content
/// beneath it. Corner radius and color are parameters so the caller can
/// match its own clip shape and accent source.
struct ActiveOutline: ViewModifier {
    let isActive: Bool
    var cornerRadius: CGFloat = 4
    var color: Color = .accentColor

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(color, lineWidth: 2)
                .opacity(isActive ? 0.6 : 0)
                .animation(.easeInOut(duration: 0.12), value: isActive)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Applies the shared active-item outline. See `ActiveOutline`.
    func activeOutline(_ isActive: Bool, cornerRadius: CGFloat = 4, color: Color = .accentColor) -> some View {
        modifier(ActiveOutline(isActive: isActive, cornerRadius: cornerRadius, color: color))
    }
}
