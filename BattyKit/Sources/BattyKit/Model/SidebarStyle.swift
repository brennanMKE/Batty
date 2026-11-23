// SidebarStyle.swift

import CoreGraphics
import Foundation

/// The Session Sidebar's presentation in one window: names (today's list) or
/// the narrow symbols-only rail. Part of the `compactSidebar` experiment.
public enum SidebarStyle: Sendable, Equatable {
    case names
    case symbols

    public var toggled: SidebarStyle {
        self == .names ? .symbols : .names
    }

    /// The menu / palette title says what choosing it will do.
    public static func toggleCommandTitle(current: SidebarStyle) -> String {
        current == .names ? "Show Symbols Only" : "Show Session Names"
    }
}

public enum SidebarRailMetrics {
    public static let namesMin: CGFloat = 180
    public static let ideal: CGFloat = 220
    public static let max: CGFloat = 320
    public static let snapThreshold: CGFloat = 120
    public static let defaultRail: CGFloat = 56
    /// Wide enough to hold the traffic lights (x ≈ 19…79 pt).
    public static let wideRail: CGFloat = 84

    /// Beta-only tuning default for trying the wider rail. Only 56 and 84 are
    /// accepted; anything else is 56.
    public static let railWidthDefaultsKey = "co.sstools.Batty.sidebarRailWidth"

    public static func railWidth(defaults: UserDefaults) -> CGFloat {
        defaults.integer(forKey: railWidthDefaultsKey) == Int(wideRail) ? wideRail : defaultRail
    }

    /// Flag off: exactly today's range. Flag on: the same range in names,
    /// and the minimum drops to the rail only while the rail shows. A rail
    /// minimum in names opens a new window's column at that minimum (VM run
    /// 20261119-121643-89581: 58 pt), so names keeps today's 180.
    public static func columnRange(compactSidebar: Bool, style: SidebarStyle, railWidth: CGFloat) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        (compactSidebar ? minimum(for: style, railWidth: railWidth) : namesMin, ideal, max)
    }

    public static func minimum(for style: SidebarStyle, railWidth: CGFloat) -> CGFloat {
        style == .symbols ? railWidth : namesMin
    }

    public static func targetWidth(for style: SidebarStyle, railWidth: CGFloat, lastNamesWidth: CGFloat?) -> CGFloat {
        switch style {
        case .symbols:
            return railWidth
        case .names:
            return Swift.min(Swift.max(lastNamesWidth ?? ideal, namesMin), max)
        }
    }

    /// Decides where a released divider drag lands. The thresholds are the
    /// same in both directions.
    public static func resolveDragEnd(width: CGFloat, railWidth: CGFloat) -> (style: SidebarStyle, width: CGFloat) {
        if width < snapThreshold { return (.symbols, railWidth) }
        if width < namesMin { return (.names, namesMin) }
        return (.names, Swift.min(width, max))
    }
}

public enum SessionRailBadge {
    public enum Glyph: Equatable, Sendable {
        case reminderDue
        case imageProblem
        case reminderPending

        public var systemName: String {
            switch self {
            case .reminderDue: "alarm.fill"
            case .imageProblem: "exclamationmark.triangle.fill"
            case .reminderPending: "clock"
            }
        }
    }

    public static func countText(_ unseen: Int) -> String? {
        guard unseen > 0 else { return nil }
        return unseen > 9 ? "9+" : String(unseen)
    }

    public static func cornerGlyph(reminderDue: Bool, imageProblem: Bool, reminderPending: Bool) -> Glyph? {
        if reminderDue { return .reminderDue }
        if imageProblem { return .imageProblem }
        if reminderPending { return .reminderPending }
        return nil
    }
}
