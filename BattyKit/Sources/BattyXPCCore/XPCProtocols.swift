// XPCProtocols.swift

import Foundation

// These are `@objc` protocols with structured payloads crossing as
// JSON-encoded `Data`, not `NSSecureCoding` classes — the approach the
// RemoteControl experiment validated (`docs/xpc/xpc-cli-architecture.md`
// "Send structured payloads as JSON-encoded Data"). It keeps class
// allowlisting out of the picture entirely; payloads are the ordinary
// `Codable, Sendable` structs in `XPCMessages.swift`.
//
// Every reply block is `@escaping @Sendable`. XPC invokes reply blocks on
// its own queues; an unannotated closure literal written inside a
// `@MainActor` call site inherits main-actor isolation and traps at
// runtime with no compiler warning (`docs/xpc/swift-concurrency-and-xpc.md`
// #1). Declaring it here makes the compiler enforce it at every call site
// this project controls.
//
// Every requirement is `nonisolated`. This project builds with
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`Package.swift`'s shared
// `swiftSettings`), which is *not* how RemoteControl's `BridgeKit` package
// was configured. Left unannotated, each protocol requirement — and any
// conforming implementation — would default to main-actor isolation, and
// XPC invokes exported-object methods on its own queues, not the main
// queue: the same class of runtime isolation trap the reply-block
// `@Sendable` rule guards against, just one layer up, at the method rather
// than the closure. Confirmed by compiling this file's protocols without
// `nonisolated` under this package's settings: the conforming method and
// every off-actor call site fail with "call to main actor-isolated
// instance method ... in a synchronous nonisolated context".

/// What the broker exposes on its Mach service (#0270).
///
/// Implemented by the broker agent; called by the app (to register its
/// endpoint) and the CLI (to reach it).
@objc public protocol BrokerProtocol {
    /// Liveness check that does not depend on the app running at all —
    /// launchd starts the broker on demand. "The most valuable diagnostic
    /// in this repo": if it succeeds, launchd owns the name; if not,
    /// nothing app-side is worth looking at.
    nonisolated func brokerPing(reply: @escaping @Sendable (String) -> Void)

    /// Called by the app after it creates its anonymous listener.
    nonisolated func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint)

    /// Called by the CLI. Replies `nil` when no app has registered.
    nonisolated func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

/// What the app exposes to a connected CLI over the direct connection
/// established after endpoint handoff (#0271).
@objc public protocol AppServiceProtocol {
    nonisolated func ping(reply: @escaping @Sendable (String) -> Void)

    /// One-shot request/reply. Both `request` and the reply payload are
    /// JSON-encoded `XPCRequest`/`XPCResponse` values (`XPCMessages.swift`).
    nonisolated func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void)

    /// #0145: long-lived streaming method. The CLI sends a `WatchSubscriptionRequest`
    /// as JSON-encoded `Data`; the app calls `reply(WatchEventPayload)` repeatedly
    /// for each matching mutation, keeps the connection alive until every subscriber
    /// closes. The request payload is `WatchSubscriptionRequest`; a failure reply
    /// (via the same block with an error sentinel) covers an unknown verb or malformed
    /// request — both are the one-shot path's job. `fromCli: true` on each event
    /// differentiates agent-driven changes from app-internal ones.
    nonisolated func watch(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Centralizes `NSXPCInterface` construction so both ends of a connection
/// configure identical interfaces. Both sides must set
/// `remoteObjectInterface`/`exportedInterface` from matching interfaces
/// *before* calling `resume()` — a mismatch fails calls silently (no error,
/// no reply, nothing in the log). Routing through this factory is the
/// cheapest available defense against that.
public nonisolated enum XPCInterfaces {
    public static var broker: NSXPCInterface {
        NSXPCInterface(with: BrokerProtocol.self)
    }

    public static var appService: NSXPCInterface {
        NSXPCInterface(with: AppServiceProtocol.self)
    }
}
