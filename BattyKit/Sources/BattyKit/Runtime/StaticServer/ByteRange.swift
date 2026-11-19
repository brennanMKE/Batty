// ByteRange.swift

import Foundation

/// A single `Range: bytes=` request. Multiple ranges get the full body.
public nonisolated enum ByteRange: Equatable, Sendable {
    case full
    case partial(ClosedRange<Int>)
    case unsatisfiable

    public static func parse(header: String?, size: Int) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        if spec.contains(",") { return .full }
        let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return .full }
        let first = pieces[0].trimmingCharacters(in: .whitespaces)
        let second = pieces[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int(second), suffix >= 0 else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int(first), start >= 0 else { return .full }
        let end: Int
        if second.isEmpty {
            end = size - 1
        } else {
            guard let value = Int(second), value >= start else { return .full }
            end = min(value, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start...end)
    }
}
