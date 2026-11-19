// ServerStats.swift

import Foundation

public nonisolated struct ServerStatsSnapshot: Equatable, Sendable {
    public var numbers: [String: Double]
    public var texts: [String: String]

    public init(numbers: [String: Double] = [:], texts: [String: String] = [:]) {
        self.numbers = numbers
        self.texts = texts
    }
}

public nonisolated enum ServerStatsParser {
    public static let maxNumericSeries = 24
    /// The `memstats` keys kept from Go's expvar; the rest are noise here.
    public static let memstatsAllowList: Set<String> = ["Alloc", "HeapAlloc", "HeapInuse", "HeapObjects", "Sys", "NumGC", "PauseTotalNs"]

    /// Nil for a body that isn't JSON or whose root isn't an object.
    public static func parse(_ data: Data, isExpvar: Bool) -> ServerStatsSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var snapshot = ServerStatsSnapshot()
        var numericKeys: [String] = []
        func visit(_ value: Any, key: String) {
            switch value {
            case let object as [String: Any]:
                for childKey in object.keys.sorted() {
                    if isExpvar, key == "memstats", !memstatsAllowList.contains(childKey) { continue }
                    visit(object[childKey]!, key: key.isEmpty ? childKey : "\(key).\(childKey)")
                }
            case let array as [Any]:
                if key == "cmdline" {
                    snapshot.texts[key] = array.map { "\($0)" }.joined(separator: " ")
                }
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    snapshot.texts[key] = number.boolValue ? "true" : "false"
                } else {
                    numericKeys.append(key)
                    snapshot.numbers[key] = number.doubleValue
                }
            case let string as String:
                snapshot.texts[key] = string
            default:
                break
            }
        }
        visit(root, key: "")
        if numericKeys.count > maxNumericSeries {
            let kept = Set(numericKeys.prefix(maxNumericSeries))
            snapshot.numbers = snapshot.numbers.filter { kept.contains($0.key) }
        }
        return snapshot
    }
}

/// The last `capacity` samples of each numeric series.
public nonisolated struct ServerStatsHistory: Equatable, Sendable {
    public static let capacity = 60
    public private(set) var series: [String: [Double]] = [:]
    public private(set) var latest = ServerStatsSnapshot()

    public init() {}

    public mutating func append(_ snapshot: ServerStatsSnapshot) {
        latest = snapshot
        for (key, value) in snapshot.numbers {
            guard series[key] != nil || series.count < ServerStatsParser.maxNumericSeries else { continue }
            var values = series[key, default: []]
            values.append(value)
            if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
            series[key] = values
        }
    }

    /// Series whose value has changed at least once; only these get a
    /// sparkline.
    public var changedKeys: Set<String> {
        Set(series.compactMap { key, values in
            guard let first = values.first, values.contains(where: { $0 != first }) else { return nil }
            return key
        })
    }
}
