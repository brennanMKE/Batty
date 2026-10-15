// SystemMetricsColors.swift

import SwiftUI

/// Colors for the System Metrics Pane's process table and utilization bars,
/// derived from the active Theme. A `nil` slot means "keep the system look".
struct SystemMetricsColors: Equatable {
    static let systemBorder = Color.primary.opacity(0.08)

    let tableBackground: Color?
    let separator: Color?
    let border: Color
    let foreground: Color?
    let mutedForeground: Color?
    let accent: Color

    init(palette: ChromePalette?) {
        tableBackground = palette?.chromeBackground
        separator = palette?.divider
        border = palette?.divider ?? Self.systemBorder
        foreground = palette?.chromeForeground
        mutedForeground = palette?.chromeMutedForeground
        accent = palette?.accent ?? Color.accentColor
    }
}
