// XPCMessages.swift

import Foundation

/// Generic request envelope carried as JSON-encoded `Data` across an XPC
/// call that expects a reply (`AppServiceProtocol.perform(_:reply:)`).
///
/// `verb` selects the operation the app should perform; `payload` carries
/// verb-specific input, itself JSON-encoded by the caller. No verb is
/// defined here — this type only establishes the wire shape. The first
/// verb (`status`) is added by #0271, which also owns whatever
/// verb-specific request/response payload `status` needs.
///
/// Marked `nonisolated` at the type level (not just its members): under
/// this package's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an
/// unannotated struct's synthesized `Codable` conformance is itself
/// main-actor-isolated, so `JSONEncoder().encode(_:)` /
/// `JSONDecoder().decode(_:from:)` fail to compile from XPC's own queues
/// (`main actor-isolated conformance ... cannot be used in nonisolated
/// context`) even when every stored property is `Sendable`. Annotating the
/// initializer alone does not fix this — the conformance itself is what's
/// isolated — so the type declaration needs the annotation.
public nonisolated struct XPCRequest: Codable, Sendable, Equatable {
    public let verb: String
    public let payload: Data?

    public init(verb: String, payload: Data? = nil) {
        self.verb = verb
        self.payload = payload
    }
}

/// Generic response envelope, mirroring `XPCRequest`. `ok` reports whether
/// the app fulfilled the request; `error` carries a human-readable failure
/// reason when `ok` is `false`. See `XPCRequest` for why this is
/// `nonisolated` at the type level.
public nonisolated struct XPCResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let payload: Data?
    public let error: String?

    public init(ok: Bool, payload: Data? = nil, error: String? = nil) {
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}
