// ProjectAppearance.swift

import AppKit
import SwiftUI

/// How a Project's symbol and color are drawn and stored beyond the legacy
/// palette. A Project keeps writing the legacy `color` and `symbol` keys with
/// the nearest legacy value, so a Mac running an older Batty still decodes
/// the file; the optional `customColor` and `symbolName` keys win when present.
public enum ProjectAppearance {
    /// `#RRGGBB`, uppercase, or nil when `text` is not six hex digits (with
    /// an optional leading `#`).
    public static func normalizedHex(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// The palette entry closest to `hex` by squared distance in RGB. Ties go
    /// to the earlier palette entry. A nil or malformed hex maps to the
    /// default, `.blue`.
    public static func nearestPalette(toHex hex: String?) -> SessionColor {
        guard let normalized = normalizedHex(hex), let target = RGBColor(hex: normalized) else { return .blue }
        var best = SessionColor.blue
        var bestDistance = Double.infinity
        for candidate in SessionColor.allCases {
            let rgb = candidate.rgb
            let distance = pow(rgb.red - target.red, 2) + pow(rgb.green - target.green, 2) + pow(rgb.blue - target.blue, 2)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// The custom color when `customHex` is valid, else the palette color.
    public static func color(palette: SessionColor, customHex: String?) -> Color {
        guard let normalized = normalizedHex(customHex), let rgb = RGBColor(hex: normalized) else { return palette.color }
        return rgb.swiftUIColor
    }

    /// The legacy case that draws exactly `systemName`, if any.
    public static func legacySymbol(forSystemName systemName: String) -> ProjectSymbol? {
        ProjectSymbol.allCases.first { $0.systemName == systemName }
    }

    /// `customName` when this OS draws it, else the legacy symbol's glyph
    /// (which itself falls back to `folder.fill`).
    public static func systemName(symbol: ProjectSymbol, customName: String?) -> String {
        if let customName, !customName.isEmpty, ProjectSymbol.exists(customName) { return customName }
        return symbol.resolvedSystemName
    }

    /// Accessibility label: the legacy display name, or the SF Symbol name.
    public static func displayName(symbol: ProjectSymbol, customName: String?) -> String {
        if let customName, !customName.isEmpty { return customName }
        return symbol.displayName
    }

    /// Canonical stored pair for a picked symbol name: a name that equals a
    /// legacy glyph is stored as that legacy case with no custom name.
    static func resolve(symbol: ProjectSymbol, customName: String?) -> (symbol: ProjectSymbol, customName: String?) {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return (symbol, nil) }
        if let legacy = legacySymbol(forSystemName: trimmed) { return (legacy, nil) }
        return (.folder, trimmed)
    }

    /// Canonical stored pair for a picked color: a custom color decides the
    /// nearest legacy palette entry.
    static func resolve(color: SessionColor, customHex: String?) -> (color: SessionColor, customHex: String?) {
        guard let normalized = normalizedHex(customHex) else { return (color, nil) }
        if let exact = SessionColor.allCases.first(where: { $0.hexString.uppercased() == normalized }) { return (exact, nil) }
        return (nearestPalette(toHex: normalized), normalized)
    }
}

extension SessionColor {
    var rgb: RGBColor {
        RGBColor(hex: hexString) ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)
    }
}
