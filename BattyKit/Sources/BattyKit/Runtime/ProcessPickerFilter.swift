// ProcessPickerFilter.swift

import Foundation

/// The Process Status picker's filter rule, kept free of view types so it
/// is unit-tested directly. Literal substring matching, not fuzzy: a
/// process name or pid is typed as-is, and a substring is what tells
/// `node` from `node_helper`.
public enum ProcessPickerFilter {
    public static func apply(_ query: String, to processes: [ProcessInspector.RunningProcess]) -> [ProcessInspector.RunningProcess] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return processes }
        let nameMatches: (ProcessInspector.RunningProcess) -> Bool = {
            $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return processes.filter(nameMatches)
        }
        let matches = processes.filter { String($0.id).hasPrefix(trimmed) || nameMatches($0) }
        let exact = matches.filter { String($0.id) == trimmed }
        guard !exact.isEmpty else { return matches }
        return exact + matches.filter { String($0.id) != trimmed }
    }
}
