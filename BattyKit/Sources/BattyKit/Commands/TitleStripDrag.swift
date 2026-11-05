// TitleStripDrag.swift

/// Whether a press in a non-opaque window's title strip should start a client
/// window drag. Opaque windows never do, so they keep AppKit's own path.
enum TitleStripDrag {
    /// Exact class names, so a renamed AppKit class falls back to AppKit's own
    /// path. The first three are what a real Mac logged for title strip presses
    /// that didn't drag a non-opaque window on macOS 27.0. Why those presses
    /// don't drag isn't known. `NSTitlebarView` wasn't in that log: it was the
    /// hit view in a replica window's title bar.
    static let draggableHitViews: Set<String> = [
        "NSToolbarPrimaryTitleContainerView",
        "NSToolbarTitleView",
        "_NSToolbarTitleField",
        "NSTitlebarView"
    ]

    /// `clickCount` must be 1 so a double-click's second press stays with
    /// AppKit. A Control or Command press does too, since those mean something
    /// other than a plain drag in a title bar.
    static func shouldStartDrag(
        hitViewClassName: String,
        isWindowOpaque: Bool,
        clickCount: Int,
        isInTitleStrip: Bool,
        controlOrCommandHeld: Bool
    ) -> Bool {
        !isWindowOpaque
            && clickCount == 1
            && isInTitleStrip
            && !controlOrCommandHeld
            && draggableHitViews.contains(hitViewClassName)
    }
}
