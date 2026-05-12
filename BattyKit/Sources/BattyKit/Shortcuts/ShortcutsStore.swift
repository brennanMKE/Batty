// ShortcutsStore.swift

import Foundation
import Observation
import OSLog
import SwiftUI

nonisolated private let shortcutsLogger = Logger(subsystem: Logging.subsystem, category: "ShortcutsStore")

/// User-customizable keyboard shortcut bindings, persisted in `UserDefaults`.
///
/// Storage key: `co.sstools.Batty.keyboardShortcuts`. Format: JSON
/// `{ "<actionID>": { "key": "...", "modifiers": <Int> } }`. Unknown keys
/// during decode are ignored (forward-compat). Missing actions fall through
/// to `ShortcutAction.defaultBinding`.
@MainActor
@Observable
public final class ShortcutsStore {
    public static let shared = ShortcutsStore()

    public private(set) var bindings: [ShortcutAction: ShortcutBinding]

    /// Hardcoded macOS-reserved combos we refuse to assign. Cmd-, is the
    /// Settings shortcut — also off-limits.
    public static let reservedShortcuts: [ShortcutBinding] = [
        ShortcutBinding(key: "q", modifiers: EventModifiers([.command]).rawValue),
        ShortcutBinding(key: "h", modifiers: EventModifiers([.command]).rawValue),
        ShortcutBinding(key: "m", modifiers: EventModifiers([.command]).rawValue),
        ShortcutBinding(key: ShortcutBinding.SpecialKey.tab.rawValue,
                        modifiers: EventModifiers([.command]).rawValue),
        ShortcutBinding(key: ",", modifiers: EventModifiers([.command]).rawValue),
    ]

    private static let defaultsKey = "co.sstools.Batty.keyboardShortcuts"
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.bindings = Self.loadFromDefaults(userDefaults: userDefaults)
    }

    // MARK: - Mutation

    public func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        bindings[action] = binding
        save()
    }

    public func resetToDefault(_ action: ShortcutAction) {
        bindings[action] = action.defaultBinding
        save()
    }

    public func resetAllToDefaults() {
        bindings = Self.defaultsForAllActions()
        save()
    }

    // MARK: - Lookup

    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        bindings[action] ?? action.defaultBinding
    }

    public func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut {
        binding(for: action).keyboardShortcut
    }

    // MARK: - Validation

    /// Other actions that share the same binding. Used by the recorder UI to
    /// surface a "Used by …" warning row.
    public func collisions(_ binding: ShortcutBinding, excluding: ShortcutAction?) -> [ShortcutAction] {
        bindings.compactMap { (action, existing) in
            guard action != excluding else { return nil }
            return existing == binding ? action : nil
        }
    }

    /// True when this binding matches one of the small hardcoded
    /// `reservedShortcuts`. The Settings UI shows a warning row when set.
    public static func isReserved(_ binding: ShortcutBinding) -> Bool {
        reservedShortcuts.contains(binding)
    }

    // MARK: - Persistence

    private static func defaultsForAllActions() -> [ShortcutAction: ShortcutBinding] {
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            result[action] = action.defaultBinding
        }
        return result
    }

    private static func loadFromDefaults(userDefaults: UserDefaults) -> [ShortcutAction: ShortcutBinding] {
        var result = defaultsForAllActions()
        guard let data = userDefaults.data(forKey: defaultsKey) else {
            return result
        }
        do {
            let decoded = try JSONDecoder().decode([String: ShortcutBinding].self, from: data)
            for (id, binding) in decoded {
                guard let action = ShortcutAction(rawValue: id) else {
                    shortcutsLogger.debug("Ignoring unknown shortcut action id: \(id, privacy: .public)")
                    continue
                }
                result[action] = binding
            }
        } catch {
            shortcutsLogger.error("Failed to decode keyboardShortcuts blob: \(error.localizedDescription, privacy: .public)")
        }
        return result
    }

    private func save() {
        var encodable: [String: ShortcutBinding] = [:]
        for (action, binding) in bindings {
            encodable[action.rawValue] = binding
        }
        do {
            let data = try JSONEncoder().encode(encodable)
            userDefaults.set(data, forKey: Self.defaultsKey)
        } catch {
            shortcutsLogger.error("Failed to encode keyboardShortcuts blob: \(error.localizedDescription, privacy: .public)")
        }
    }
}
