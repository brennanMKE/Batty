// ProcessIdentifierFormatting.swift

import Foundation

/// Identifiers (PIDs, file-descriptor numbers) are not quantities: they must
/// never pass through `LocalizedStringKey` or a number formatter, which would
/// insert a locale grouping separator ("6,044").
public enum ProcessIdentifierFormatting {
    public static func identifier(_ value: some BinaryInteger) -> String {
        String(value)
    }
}
