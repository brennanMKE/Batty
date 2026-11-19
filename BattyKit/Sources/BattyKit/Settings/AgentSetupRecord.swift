// AgentSetupRecord.swift

import CryptoKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AgentSetupRecord")

/// The agent hosts the user installed from Settings, each with the guidance
/// last written for it. No record, or no hosts, means never set up.
public nonisolated struct AgentSetupRecord: Codable, Equatable, Sendable {
    public struct InstalledHost: Codable, Equatable, Sendable {
        public var fingerprint: String?
        public var version: String?
        public var updatedAt: Date?

        public init(fingerprint: String? = nil, version: String? = nil, updatedAt: Date? = nil) {
            self.fingerprint = fingerprint
            self.version = version
            self.updatedAt = updatedAt
        }
    }

    /// Keyed by `AgentHost.rawValue`.
    public var hosts: [String: InstalledHost]
    public var lastProblems: [String]

    public init(hosts: [String: InstalledHost] = [:], lastProblems: [String] = []) {
        self.hosts = hosts
        self.lastProblems = lastProblems
    }

    public var installedHosts: Set<AgentHost> {
        Set(hosts.keys.compactMap(AgentHost.init(rawValue:)))
    }

    public func installed(_ host: AgentHost) -> InstalledHost? {
        hosts[host.rawValue]
    }

    /// Adds or updates the plan's hosts; other recorded hosts are kept.
    public func recording(plan: AgentInstallPlan, report: AgentInstallReport, fingerprint: String?, at date: Date) -> AgentSetupRecord {
        var copy = self
        for host in plan.hosts {
            copy.hosts[host.rawValue] = InstalledHost(fingerprint: fingerprint, version: plan.identity.version, updatedAt: date)
        }
        copy.lastProblems = report.problemLines
        return copy
    }

    public func removing(_ removed: Set<AgentHost>) -> AgentSetupRecord {
        var copy = self
        for host in removed { copy.hosts[host.rawValue] = nil }
        return copy
    }
}

/// Reads and writes the record in an injected defaults domain (one per variant).
public nonisolated struct AgentSetupRecordStore: @unchecked Sendable {
    public static let key = "co.sstools.Batty.agentSetup"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> AgentSetupRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(AgentSetupRecord.self, from: data)
        } catch {
            logger.error("Undecodable agent setup record: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(_ record: AgentSetupRecord) {
        do {
            defaults.set(try JSONEncoder().encode(record), forKey: Self.key)
        } catch {
            logger.error("Could not encode agent setup record: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Changes when the app's version, its CLI path or its bundled skill changes.
/// Beta builds share one version number, so the skill's hash is part of it.
public nonisolated enum AgentGuidanceFingerprint {
    public static func make(identity: AgentGuidanceIdentity) -> String? {
        let skill = identity.skillSourceDirectory.appending(path: "SKILL.md", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: skill) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return [identity.version, identity.cliExecutablePath, hash].joined(separator: "\n")
    }
}
