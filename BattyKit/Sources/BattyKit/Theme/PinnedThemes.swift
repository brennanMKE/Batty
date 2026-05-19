// PinnedThemes.swift

import Foundation

public struct PinnedThemes: Sendable {
    public static let defaultsKey = "co.sstools.Batty.pinnedThemeIDs"

    public static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    public static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: defaultsKey)
    }

    public static func toggle(_ name: String, in current: inout [String]) {
        if current.contains(name) {
            current.removeAll { $0 == name }
        } else {
            current.append(name)
        }
    }

    public static func contains(_ name: String, in ids: [String]) -> Bool {
        ids.contains(name)
    }
}
