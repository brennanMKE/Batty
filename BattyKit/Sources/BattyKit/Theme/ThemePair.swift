// ThemePair.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ThemePair")

/// A Dark Theme name and a Light Theme name, either of which may be unset.
/// An unset slot follows the app-wide Theme for that appearance. Names are
/// not checked against the catalog: an unknown name is data and round-trips.
public struct ThemePair: Codable, Sendable, Hashable {
    public let dark: String?
    public let light: String?

    static let maxNameBytes = 128

    public init(dark: String?, light: String?) {
        self.dark = Self.clean(dark)
        self.light = Self.clean(light)
    }

    public static func both(_ name: String) -> ThemePair {
        ThemePair(dark: name, light: name)
    }

    public func name(isDark: Bool) -> String? {
        isDark ? dark : light
    }

    public var isEmpty: Bool { dark == nil && light == nil }

    /// `nil` when both slots are unset, so "no Theme" has one representation.
    public var normalized: ThemePair? { isEmpty ? nil : self }

    public func with(_ name: String?, isDark: Bool) -> ThemePair {
        isDark ? ThemePair(dark: name, light: light) : ThemePair(dark: dark, light: name)
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isValid(_ name: String) -> Bool {
        name.utf8.count <= maxNameBytes && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case dark, light
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(dark: Self.decodeSlot(.dark, in: container), light: Self.decodeSlot(.light, in: container))
    }

    private static func decodeSlot(_ key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>) -> String? {
        guard container.contains(key) else { return nil }
        guard let name = try? container.decodeIfPresent(String.self, forKey: key) else {
            logger.error("ThemePair: \(key.rawValue, privacy: .public) is not a string; following Settings")
            return nil
        }
        guard isValid(name) else {
            logger.error("ThemePair: \(key.rawValue, privacy: .public) is not a valid Theme name; following Settings")
            return nil
        }
        return name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(dark, forKey: .dark)
        try container.encodeIfPresent(light, forKey: .light)
    }
}
