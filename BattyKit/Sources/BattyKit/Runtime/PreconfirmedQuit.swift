// PreconfirmedQuit.swift

import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "PreconfirmedQuit")

/// A quit the user has already confirmed elsewhere (Sparkle's Install and
/// Relaunch) skips the "Quit Batty?" alert once. The next terminate request
/// consumes the mark whatever its outcome.
@MainActor
public final class PreconfirmedQuit {
    public static let shared = PreconfirmedQuit()

    public enum Reason: String, Sendable {
        case sparkleInstall
    }

    public private(set) var pending: Reason?

    public init() {}

    public func mark(_ reason: Reason) {
        pending = reason
        logger.info("mark \(reason.rawValue, privacy: .public)")
    }

    public func consume() -> Reason? {
        guard let reason = pending else { return nil }
        pending = nil
        logger.info("consume \(reason.rawValue, privacy: .public)")
        return reason
    }

    public func clear() {
        guard let reason = pending else { return }
        pending = nil
        logger.info("clear \(reason.rawValue, privacy: .public)")
    }
}
