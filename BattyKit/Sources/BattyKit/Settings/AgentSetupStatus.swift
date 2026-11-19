// AgentSetupStatus.swift

import Foundation

/// One row of Settings' agent host list.
public nonisolated struct AgentHostStatus: Equatable, Sendable, Identifiable {
    public enum State: Equatable, Sendable {
        case notFound
        case notInstalled
        case installed(version: String?)
        case updateAvailable(version: String?)
    }

    public let host: AgentHost
    public let state: State
    /// What installing writes for this host.
    public let writes: String

    public var id: AgentHost { host }

    public static let order: [AgentHost] = [.claudeCode, .codex, .cursor, .openCode, .crossTool]

    public static func statuses(plan: AgentInstallPlan, record: AgentSetupRecord?, fingerprint: String) -> [AgentHostStatus] {
        order.map { host in
            let state: State
            if let installed = record?.installed(host) {
                state = installed.fingerprint == fingerprint ? .installed(version: installed.version) : .updateAvailable(version: installed.version)
            } else {
                state = plan.hosts.contains(host) ? .notInstalled : .notFound
            }
            return AgentHostStatus(host: host, state: state, writes: writes(for: host))
        }
    }

    public static func displayName(_ host: AgentHost) -> String {
        host == .crossTool ? String(localized: "Other agents") : host.rawValue
    }

    static func writes(for host: AgentHost) -> String {
        switch host {
        case .claudeCode: String(localized: "Plugin with MCP server, skill and session hook")
        case .codex: String(localized: "MCP server in ~/.codex/config.toml, and a skill")
        case .cursor: String(localized: "MCP server in ~/.cursor/mcp.json, and a skill")
        case .openCode: String(localized: "MCP server in opencode.json, and a skill")
        case .crossTool: String(localized: "Skill in ~/.agents/skills")
        }
    }
}
