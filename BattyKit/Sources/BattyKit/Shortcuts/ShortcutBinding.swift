// ShortcutBinding.swift

import SwiftUI

/// Codable wrapper around a SwiftUI `KeyboardShortcut`. Persisted as JSON inside
/// the `keyboardShortcuts` `UserDefaults` blob (see `ShortcutsStore`).
///
/// Two flavors of `key`:
/// - **Single character** (e.g. `"t"`, `"1"`, `"/"`) — passed through to
///   `KeyEquivalent(Character)`.
/// - **Special key sentinel** (one of `SpecialKey.rawValue`s, e.g.
///   `"leftArrow"`) — mapped to a `KeyEquivalent` like `.leftArrow`.
///
/// `modifiers` is the raw bitfield of `SwiftUI.EventModifiers`.
public struct ShortcutBinding: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: Int

    public init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }

    public enum SpecialKey: String, CaseIterable, Sendable {
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case `return`
        case escape
        case tab
        case space
        case delete

        public var keyEquivalent: KeyEquivalent {
            switch self {
            case .leftArrow:  return .leftArrow
            case .rightArrow: return .rightArrow
            case .upArrow:    return .upArrow
            case .downArrow:  return .downArrow
            case .return:     return .return
            case .escape:     return .escape
            case .tab:        return .tab
            case .space:      return .space
            case .delete:     return .delete
            }
        }

        /// Glyph used in the recorder UI for this special key.
        public var glyph: String {
            switch self {
            case .leftArrow:  return "\u{2190}"     // ←
            case .rightArrow: return "\u{2192}"     // →
            case .upArrow:    return "\u{2191}"     // ↑
            case .downArrow:  return "\u{2193}"     // ↓
            case .return:     return "\u{21A9}"     // ↩
            case .escape:     return "\u{238B}"     // ⎋
            case .tab:        return "\u{21E5}"     // ⇥
            case .space:      return "Space"
            case .delete:     return "\u{232B}"     // ⌫
            }
        }
    }

    /// `true` when this binding's `key` field is one of the `SpecialKey` rawValues.
    public var specialKey: SpecialKey? {
        SpecialKey(rawValue: key)
    }

    /// Convert to a SwiftUI `KeyboardShortcut` for use with `.keyboardShortcut(_:)`.
    public var keyboardShortcut: KeyboardShortcut {
        let mods = EventModifiers(rawValue: modifiers)
        if let special = specialKey {
            return KeyboardShortcut(special.keyEquivalent, modifiers: mods)
        }
        let ch = key.first ?? " "
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: mods)
    }

    /// Pretty-printed glyph form (e.g. `"⌘⇧→"`) for the Settings pane.
    public var displayString: String {
        let mods = EventModifiers(rawValue: modifiers)
        var s = ""
        if mods.contains(.control) { s += "\u{2303}" } // ⌃
        if mods.contains(.option)  { s += "\u{2325}" } // ⌥
        if mods.contains(.shift)   { s += "\u{21E7}" } // ⇧
        if mods.contains(.command) { s += "\u{2318}" } // ⌘

        if let special = specialKey {
            s += special.glyph
        } else {
            s += key.uppercased()
        }
        return s
    }
}
