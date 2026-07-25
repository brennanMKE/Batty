// BrokerAgentController.swift

import BattyXPCCore
import Foundation
import ServiceManagement
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "BrokerAgentController")

/// Batty's own mapping of `SMAppService.Status`, kept separate so the
/// mapping logic (the part that actually varies and is worth testing) is a
/// pure function independent of `SMAppService` itself.
///
/// Deliberately *not* named or presented as a health state: `SMAppService
/// .status` can report `.enabled` while launchd has no such service
/// (observed directly in the reference project after `launchctl bootout`).
/// A round trip (`batty ping`) is the only thing allowed to claim the
/// broker is actually reachable — see #0270's binding constraint. This type
/// only ever describes what `SMAppService` believes about registration.
public enum BrokerAgentRegistrationState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case unknown

    public init(status: SMAppService.Status) {
        switch status {
        case .notRegistered, .notFound:
            self = .notRegistered
        case .requiresApproval:
            self = .requiresApproval
        case .enabled:
            self = .enabled
        @unknown default:
            self = .unknown
        }
    }
}

/// Thin wrapper around `SMAppService.agent(plistName:)` for the broker
/// agent, plus a status UI can bind to. Registration only; the failed-call
/// -driven repair path (unregister-then-reregister on a wedged state) is
/// #0272's scope, not this type's.
@MainActor
@Observable
public final class BrokerAgentController {
    public private(set) var state: BrokerAgentRegistrationState = .unknown
    public private(set) var lastErrorDescription: String?

    /// Whether this bundle actually shipped the agent plist. `SMAppService
    /// .agent(plistName:)` always succeeds at construction regardless — it
    /// only fails (as `.notRegistered`, indistinguishable from "never
    /// registered") once `register()` is called. Without this check a Beta
    /// build (which never embeds the broker — see #0270's Prod-only
    /// decision) would offer a "Register" button that can only fail.
    public let isEmbedded: Bool

    private let service: SMAppService

    public init(
        plistName: String = ServiceNames.agentPlistName,
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.service = SMAppService.agent(plistName: plistName)
        self.isEmbedded = Self.agentIsEmbedded(bundleURL: bundleURL, plistName: plistName, fileManager: fileManager)
        refresh()
    }

    static func agentIsEmbedded(bundleURL: URL, plistName: String, fileManager: FileManager) -> Bool {
        let path = bundleURL
            .appending(path: "Contents/Library/LaunchAgents/\(plistName)", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        return fileManager.fileExists(atPath: path)
    }

    public func refresh() {
        state = BrokerAgentRegistrationState(status: service.status)
    }

    public func register() {
        do {
            try service.register()
            lastErrorDescription = nil
            logger.info("broker agent register() succeeded")
        } catch {
            lastErrorDescription = error.localizedDescription
            logger.error("broker agent register() failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    public func unregister() {
        do {
            try service.unregister()
            lastErrorDescription = nil
            logger.info("broker agent unregister() succeeded")
        } catch {
            lastErrorDescription = error.localizedDescription
            logger.error("broker agent unregister() failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }
}
