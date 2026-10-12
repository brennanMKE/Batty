// ProjectStartupTrust.swift

import CryptoKit
import Foundation

/// One line of the trust sheet: where a command lives and what it says.
public struct ProjectStartupCommandRow: Sendable, Hashable, Identifiable {
    public var paneIndex: Int
    public var tabIndex: Int
    public var label: String
    public var command: String

    public var id: String { "\(paneIndex).\(tabIndex)" }
}

public enum ProjectStartupDecision: Sendable, Equatable {
    case skip
    case runWithoutPrompt
    case prompt
}

public enum ProjectStartupChoice: Sendable, Equatable {
    case openWithoutRunning
    case run(rememberApproval: Bool)
}

public struct ProjectStartupOutcome: Sendable, Equatable {
    public var runCommands: Bool
    public var hashToStore: String?
}

/// The decision logic behind the startup-command trust sheet. Pure: nothing
/// here touches the store, a window or a terminal.
public enum ProjectStartupTrust {
    public static func decide(_ project: Project) -> ProjectStartupDecision {
        guard project.runStartupCommandsOnOpen, !project.startupCommands.isEmpty else {
            return .skip
        }
        return project.approvedCommandsHash == project.startupCommandsHash ? .runWithoutPrompt : .prompt
    }

    public static func outcome(for choice: ProjectStartupChoice, project: Project) -> ProjectStartupOutcome {
        switch choice {
        case .openWithoutRunning:
            ProjectStartupOutcome(runCommands: false, hashToStore: nil)
        case .run(let remember):
            ProjectStartupOutcome(runCommands: true, hashToStore: remember ? project.startupCommandsHash : nil)
        }
    }

    public static func rows(for project: Project) -> [ProjectStartupCommandRow] {
        project.startupCommands.map { entry in
            let pane = project.layout.panes[entry.paneIndex]
            let title = pane.tabs[entry.tabIndex].title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (title?.isEmpty ?? true) ? "Tab \(entry.tabIndex + 1)" : title!
            return ProjectStartupCommandRow(
                paneIndex: entry.paneIndex,
                tabIndex: entry.tabIndex,
                label: "Pane \(entry.paneIndex + 1) \u{00B7} \(label)",
                command: StartupCommandDelivery.lines(from: entry.command).joined(separator: "\n")
            )
        }
    }
}

extension Project {
    /// SHA-256, as lowercase hex, over the ordered (Pane index, Tab index,
    /// working directory, command) of every non-blank startup command. A
    /// Tab's title is deliberately not part of it. `hashValue` is seeded per
    /// process, so the digest has to be computed over an explicit encoding.
    public var startupCommandsHash: String {
        var bytes = Data()
        func append(_ field: String) {
            bytes.append(contentsOf: Array(String(field.utf8.count).utf8))
            bytes.append(0x3A)
            bytes.append(contentsOf: Array(field.utf8))
            bytes.append(0x1F)
        }
        append(Project.standardizedRoot(rootPath))
        bytes.append(0x1E)
        for entry in startupCommands {
            let directory = layout.panes[entry.paneIndex].tabs[entry.tabIndex].workingDirectory
            for field in ["\(entry.paneIndex)", "\(entry.tabIndex)", directory, entry.command] {
                append(field)
            }
            bytes.append(0x1E)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
