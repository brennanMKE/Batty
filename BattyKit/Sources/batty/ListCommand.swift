// ListCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty list` — the Tier 3 topology read verb (#0274): windows, their
/// sessions, and each session's pane/tab tree, over the same hardened XPC
/// channel `batty status` (#0271) uses. Closes #0257's `pane show <id>`
/// discovery gap once that verb exists — hidden panes appear here with
/// `isHidden: true`.
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List windows, sessions, panes, and tabs from a running Batty."
    )

    enum Scope: String, ExpressibleByArgument {
        case sessions
        case panes
        case tabs
    }

    @Argument(help: "Restrict the plain-text listing to sessions, panes, or tabs. Defaults to sessions. Ignored by --json, which always reports the full topology — slice it with a tool like jq instead.")
    var scope: Scope?

    @Flag(name: .long, help: "Emit JSON instead of a plain-text summary.")
    var json = false

    @Flag(name: .long, help: "Include `frame` and `visibleRect` dimensions in pane objects. Not included by default.")
    var includeDimensions = false

    nonisolated func run() throws {
        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        



        case .success(let endpoint):
            switch AppServiceClient.list(endpoint: endpoint, includeDimensions: includeDimensions, timeout: 3.0) {
            case .success(let payload):
                if json {
                    try Self.printJSON(payload)
                } else {
                    Self.printPlainText(payload, scope: scope ?? .sessions, includeDimensions: includeDimensions)
                }
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }



    }

    private static func printJSON(_ payload: TopologyPayload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            fputs("batty: failed to encode topology as JSON\n", stderr)
            throw ExitCode.failure
        }
        print(text)
    }

    




    private static func printPlainText(_ payload: TopologyPayload, scope: Scope, includeDimensions: Bool) {
        for window in payload.windows {
            switch scope {
            case .sessions:
                for session in window.sessions {
                    print(sessionLine(session))
                }
            case .panes:
                for session in window.sessions {
                    for pane in session.allPanes {
                        print(paneLine(pane, session: session, includeDimensions: includeDimensions))
                    }
                }
            case .tabs:
                for session in window.sessions {
                    for pane in session.allPanes {
                        for tab in pane.tabs {
                            print(tabLine(tab, pane: pane, session: session))
                        }
                    }
                }
            }
        }
    }

    private static func sessionLine(_ session: TopologySessionPayload) -> String {
        let flags = session.isActive ? " active" : ""
        let path = session.path.map { " path=\($0)" } ?? ""
        let paneCount = session.allPanes.count
        return "session \(session.id) \"\(session.name)\"\(flags) panes=\(paneCount)\(path)"
    }

    private static func paneLine(_ pane: TopologyPanePayload, session: TopologySessionPayload, includeDimensions: Bool) -> String {
        var flags: [String] = []
        if pane.isHidden { flags.append("hidden") }
        if pane.isFocused { flags.append("focused") }
        var dims = ""
        if includeDimensions {
            if let frame = pane.frame {
                dims += " frame=\(frame.x),\(frame.y),\(frame.width)x\(frame.height)"
            }
            if let visibleRect = pane.visibleRect {
                dims += " visible=\(visibleRect.x),\(visibleRect.y),\(visibleRect.width)x\(visibleRect.height)"
            }
        }
        let flagText = flags.isEmpty ? "" : " " + flags.joined(separator: " ")
        return "pane \(pane.id) session=\(session.id)\(flagText) tabs=\(pane.tabs.count)\(dims)"
    }




    private static func tabLine(_ tab: TopologyTabPayload, pane: TopologyPanePayload, session: TopologySessionPayload) -> String {
        let flags = tab.isActive ? " active" : ""
        let cwd = tab.workingDirectory.map { " cwd=\($0)" } ?? ""
        return "tab \(tab.id) pane=\(pane.id) session=\(session.id) \"\(tab.title)\"\(flags)\(cwd)"
    }
}
