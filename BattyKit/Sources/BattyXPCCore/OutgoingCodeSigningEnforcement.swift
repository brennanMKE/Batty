// OutgoingCodeSigningEnforcement.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "OutgoingCodeSigningEnforcement")

/// Applies the peer code-signing requirement to an *outgoing*
/// `NSXPCConnection` — the counterpart to `setConnectionCodeSigningRequirement`
/// on the listener side (#0273's `BattyBroker/main.swift` and
/// `AppXPCCoordinator.start()`). #0273 only validated *incoming* connections;
/// this closes the other direction for the four call sites that construct an
/// outgoing connection: app→broker (`AppXPCCoordinator`), CLI→broker
/// (`BrokerPingClient`, `BrokerAppEndpointClient`), and CLI→app
/// (`AppServiceClient`, over the endpoint the broker hands back — data, not
/// something launchd vouches for).
///
/// Self-derives from `OwnCodeSigningIdentity.currentTeamIdentifier()` exactly
/// as the listener sites do, so a `nil` team identifier (ad-hoc/unsigned
/// local build) skips enforcement entirely rather than failing every dev
/// connection closed — see `PeerCodeSigningRequirement`'s doc comment. Each
/// process's outgoing enforcement is independent of what it enforces as a
/// listener: an ad-hoc CLI validates nothing about the broker it connects to
/// (this enum's `nil` branch), while a properly signed broker/app still
/// reject that same ad-hoc CLI on the *listener* side. That asymmetry is the
/// escape hatch working as intended, not a gap this type should close.
///
/// Per SDK header (`NSXPCConnection.h`): a malformed requirement string
/// throws an Objective-C exception, but `PeerCodeSigningRequirement` only
/// ever produces the one well-formed shape or `nil`, so that path is not
/// live here. A *mismatched* peer does not surface as a catchable error on
/// this call — the connection is invalidated once traffic doesn't match,
/// which every one of the four call sites already treats as "unreachable"
/// via `interruptionHandler`/`invalidationHandler`/the proxy's error
/// handler. No new error path is needed to route a rejected impostor into
/// the existing exit-code vocabulary.
public nonisolated enum OutgoingCodeSigningEnforcement {
    /// Call before `connection.resume()` — matching the listener sites'
    /// placement and the SDK header's "recommended... before calling resume"
    /// note.
    public static func apply(to connection: NSXPCConnection, context: String) {
        if let requirement = PeerCodeSigningRequirement.requirement(forTeamIdentifier: OwnCodeSigningIdentity.currentTeamIdentifier()) {
            connection.setCodeSigningRequirement(requirement)
            logger.info("\(context, privacy: .public): peer code-signing requirement enforced")
        } else {
            logger.notice("\(context, privacy: .public): running unsigned/ad-hoc — accepting any peer (dev-only)")
        }
    }
}
