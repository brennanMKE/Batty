// WindowSeeThrough.swift

import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Whether this content window shows the desktop through its terminals.
    /// Set once by `RootWindowView`, so children read one `Bool`, not every Pane.
    @Entry var windowIsSeeThrough = false
}

/// What a content window paints while a terminal in it is below full opacity.
/// Only the terminal rectangle is clear; all other chrome stays solid.
enum WindowSeeThrough {
    /// Black, not white, because white at this alpha shifted a glass Sidebar to
    /// mid gray when measured. Not `.clear`, which loses the solid system title
    /// bar. 0.004 rounds to 1/255 in the window; 0.001 rounds to zero.
    static let windowColor = NSColor.black.withAlphaComponent(0.004)

    static func backdropFill(isSeeThrough: Bool, hasSelectedSession: Bool, windowBackground: Color?) -> Color {
        guard isSeeThrough else { return windowBackground ?? .clear }
        return hasSelectedSession ? .clear : solid(windowBackground)
    }

    /// With no Theme the system title bar is already solid in a see-through window.
    static func titlebarFill(isSeeThrough: Bool, windowBackground: Color?) -> Color {
        guard isSeeThrough else { return .clear }
        return windowBackground ?? .clear
    }

    static func chromeBacking(isSeeThrough: Bool, windowBackground: Color?) -> Color {
        isSeeThrough ? solid(windowBackground) : .clear
    }

    /// `nil` keeps the Sidebar's unthemed glass, whose look over the desktop
    /// isn't predictable, so a see-through window takes the themed code path.
    static func sidebarFill(isSeeThrough: Bool, chromeBackground: Color?) -> Color? {
        if let chromeBackground { return chromeBackground }
        return isSeeThrough ? Color(nsColor: .windowBackgroundColor) : nil
    }

    /// A painted row background removes the system's selection chrome, so a
    /// see-through Sidebar with no Theme has to draw its own, at the strength
    /// `ChromePalette` uses for a Theme's foreground.
    static func sidebarSelectionTint(isSeeThrough: Bool, themeTint: Color?) -> Color? {
        if let themeTint { return themeTint }
        return isSeeThrough ? Color.primary.opacity(0.12) : nil
    }

    /// The `isOpaque` flip changes `NSThemeFrame`'s subviews, so callers must
    /// run this off the SwiftUI update, never inside the layout pass.
    static func apply(palette: ChromePalette, isSeeThrough: Bool, to window: NSWindow) {
        if isSeeThrough {
            window.titlebarAppearsTransparent = palette.windowBackground != nil
            window.backgroundColor = windowColor
            window.ignoresMouseEvents = false
            if window.isOpaque {
                window.isOpaque = false
                window.invalidateShadow()
            }
            return
        }
        if let background = palette.windowBackground {
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(background)
        } else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = nil
        }
        if !window.isOpaque {
            window.isOpaque = true
            window.invalidateShadow()
        }
    }

    private static func solid(_ windowBackground: Color?) -> Color {
        windowBackground ?? Color(nsColor: .windowBackgroundColor)
    }
}
