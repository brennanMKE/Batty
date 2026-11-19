// ShellCommandJoiner.swift

import Foundation

/// Turns the arguments after `--` into one line of shell text. A single
/// argument is used verbatim, so `-- "go run . | tee log"` keeps its pipe;
/// several are POSIX-quoted one by one and joined with spaces.
public nonisolated enum ShellCommandJoiner {
    public static func join(_ arguments: [String]) -> String {
        if arguments.count == 1 { return arguments[0] }
        return arguments.map(quote).joined(separator: " ")
    }

    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")

    public static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
