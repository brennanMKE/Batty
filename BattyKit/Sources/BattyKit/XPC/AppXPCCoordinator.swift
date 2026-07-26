// AppXPCCoordinator.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppXPCCoordinator")

/// Owns the app-side anonymous XPC listener, its registration with the
/// broker (#0271), and the lifecycle hardening around both (#0272): the app
/// re-registers automatically after a broker restart, tells connected CLIs
/// before quitting rather than just dropping them, and repairs a wedged
/// `SMAppService` registration when — and only when — a real call fails.
@MainActor
public final class AppXPCCoordinator {
    public private(set) var isRegisteredWithBroker = false

    private let service = AppXPCService()
    private let connectionRegistry = AppXPCConnectionRegistry()
    private let repairGuard: BrokerRepairGuard
    private let reconnectBudget: BrokerReconnectBudget
    private let brokerAgentController: BrokerAgentController
    private var listener: NSXPCListener?
    private var listenerDelegate: AppXPCListenerDelegate?
    private var brokerConnection: NSXPCConnection?
    /// This app's variant (Prod or Beta), derived once in `start()` from
    /// `Bundle.main.bundleIdentifier` and reused for every broker name
    /// this coordinator resolves (#0277). `nil` only before `start()` has
    /// run, or if the bundle identifier matched neither known variant —
    /// in which case `start()` never resumed the listener and nothing
    /// else in this type runs.
    private var variant: ServiceNames.Variant?
    /// Monotonic counter, incremented once per `connectToBroker` call and
    /// captured by value into that connection's handler closures — this is
    /// what `currentBrokerGeneration` is compared against via
    /// `BrokerConnectionSignalAdmission`, instead of an `ObjectIdentifier`
    /// (round 2 review: `ObjectIdentifier` uniqueness holds only among
    /// objects alive at the same time, and this coordinator repeatedly nils
    /// a connection and allocates its replacement with no intervening
    /// retain — exactly the shape that can reuse an address).
    private var brokerConnectionGeneration: UInt64 = 0
    /// Generation of `brokerConnection`, checked against
    /// `BrokerConnectionSignalAdmission` — the guard against #0272's
    /// identity-confusion defect (see that type's doc comment). `nil`
    /// exactly when `brokerConnection` is `nil`; every assignment to one is
    /// paired with the other.
    private var currentBrokerGeneration: UInt64?
    private var listenerEndpoint: NSXPCListenerEndpoint?

    public init(
        repairGuard: BrokerRepairGuard = BrokerRepairGuard(),
        reconnectBudget: BrokerReconnectBudget = BrokerReconnectBudget(),
        brokerAgentController: BrokerAgentController = BrokerAgentController()
    ) {
        self.repairGuard = repairGuard
        self.reconnectBudget = reconnectBudget
        self.brokerAgentController = brokerAgentController
    }

    public func start() {
        // #0277: each variant derives its own broker/agent names from
        // Bundle.main.bundleIdentifier, so Prod talking to Prod's broker
        // and Beta talking to Beta's broker can no longer collide by
        // construction — that replaces #0271's fail-closed guard, which
        // existed only because the broker identity used to be invariant
        // across variants. An identifier that matches neither known
        // variant (a rename, a fork, a bundle id typo) still fails closed
        // here rather than guessing.
        guard let variant = ServiceNames.Variant(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            logger.error("start: bundle identifier \(Bundle.main.bundleIdentifier ?? "<nil>", privacy: .public) does not match any known Batty variant — not starting the XPC listener")
            return
        }
        self.variant = variant

        let listener = NSXPCListener.anonymous()
        // #0273: same peer requirement as the broker (`main.swift` in
        // BattyBroker) — see `PeerCodeSigningRequirement` for why a `nil`
        // team identifier (ad-hoc/unsigned dev build) deliberately skips
        // enforcement rather than failing every local connection closed.
        if let requirement = PeerCodeSigningRequirement.requirement(forTeamIdentifier: OwnCodeSigningIdentity.currentTeamIdentifier()) {
            listener.setConnectionCodeSigningRequirement(requirement)
            logger.info("peer code-signing requirement enforced")
        } else {
            logger.notice("running unsigned/ad-hoc — accepting any peer (dev-only)")
        }
        let delegate = AppXPCListenerDelegate(exportedObject: service, connectionRegistry: connectionRegistry)
        listener.delegate = delegate
        listener.resume()
        self.listener = listener
        self.listenerDelegate = delegate
        self.listenerEndpoint = listener.endpoint
        logger.info("anonymous listener resumed")
        connectToBroker(endpoint: listener.endpoint)
    }

    /// Tells connected CLIs the app is quitting, then tears everything down
    /// deliberately (#0272 item 4). Call synchronously from
    /// `applicationWillTerminate` — everything here is lock-protected,
    /// synchronous bookkeeping (no `Task` hops), so it completes before the
    /// method returns rather than racing process exit.
    ///
    /// Clearing `currentBrokerGeneration` here — before `invalidate()`
    /// below asynchronously fires this connection's `invalidationHandler`
    /// — is what stops that handler's later-arriving signal from
    /// re-registering a process that is already on its way out (#0272's
    /// defect A): by the time it runs, `BrokerConnectionSignalAdmission`
    /// sees `currentGeneration == nil`, which can never match a real
    /// signal's generation, so the signal is dropped as stale.
    public func prepareForTermination() {
        logger.info("prepareForTermination: \(self.connectionRegistry.count, privacy: .public) client connection(s), notifying before teardown")
        service.shutdown()
        connectionRegistry.invalidateAll()
        currentBrokerGeneration = nil
        brokerConnection?.invalidate()
        brokerConnection = nil
    }

    // MARK: - Broker connection lifecycle

    private func connectToBroker(endpoint: NSXPCListenerEndpoint) {
        guard let variant else {
            logger.error("connectToBroker: called before a variant was resolved — not connecting")
            return
        }
        let connection = NSXPCConnection(machServiceName: ServiceNames.broker(for: variant))
        connection.remoteObjectInterface = XPCInterfaces.broker
        // #0278: the outgoing counterpart to #0273's listener-side check —
        // without this, a process that owns the broker's Mach service name
        // could impersonate it to the app. See
        // `OutgoingCodeSigningEnforcement` for the nil-team dev escape hatch.
        OutgoingCodeSigningEnforcement.apply(to: connection, context: "app→broker")
        // Captured by value into every handler below, alongside `[weak
        // self]` — a monotonic `UInt64`, not `ObjectIdentifier(connection)`
        // (round 2 review: address-derived identity can collide once the
        // old connection deallocates and a replacement is allocated with no
        // intervening retain, which is exactly what `.rebuildConnection`
        // and `attemptRepairIfNeeded` do). This is what lets
        // `handleBrokerSignal`/`handleBrokerCallFailure` tell a signal from
        // *this* connection apart from one arriving late from a connection
        // this coordinator has since discarded (#0272's defect A/B; see
        // `BrokerConnectionSignalAdmission`).
        brokerConnectionGeneration += 1
        let generation = brokerConnectionGeneration
        // Every Foundation-supplied handler closure here is `@Sendable` and
        // hops back with `Task { @MainActor ... }` — the SIGTRAP trap this
        // whole child is written against (`docs/xpc/swift-concurrency-and-xpc.md`
        // #1). Skipping `@Sendable` compiles clean under strict concurrency
        // and crashes at runtime with nothing logged, because the crash is
        // inside the handler that would have logged it.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBrokerSignal(.interruption, generation: generation)
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBrokerSignal(.invalidation, generation: generation)
            }
        }
        connection.resume()
        brokerConnection = connection
        currentBrokerGeneration = generation
        registerEndpoint(endpoint, over: connection, generation: generation)
    }

    private func registerEndpoint(_ endpoint: NSXPCListenerEndpoint, over connection: NSXPCConnection, generation: UInt64) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleBrokerCallFailure("broker unreachable: \(error.localizedDescription)", generation: generation)
            }
        }) as? BrokerProtocol else {
            handleBrokerCallFailure("failed to obtain broker proxy", generation: generation)
            return
        }

        // registerAppEndpoint is one-way and gives no delivery confirmation
        // — a subsequent round trip (brokerPing) is what confirms the
        // broker actually received it, never the call returning
        // (`docs/xpc/xpc-cli-architecture.md` "Confirm registration with a
        // round trip, not a return" — #0272 item 6's audit rule applied
        // again here, on the retry paths this child adds).
        proxy.registerAppEndpoint(endpoint)
        proxy.brokerPing { @Sendable [weak self] description in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard BrokerConnectionSignalAdmission.isCurrent(signalGeneration: generation, currentGeneration: self.currentBrokerGeneration) else {
                    logger.notice("brokerPing reply from a superseded connection — ignoring")
                    return
                }
                self.isRegisteredWithBroker = true
                self.reconnectBudget.reset()
                logger.info("endpoint registered and confirmed — \(description, privacy: .public)")
            }
        }
    }

    /// Distinct interruption/invalidation dispatch (#0272 item 1), via the
    /// pure `BrokerConnectionLifecycle` mapping — this method is the only
    /// place that turns the mapped action into a real reconnect attempt, and
    /// every attempt is bounded by `reconnectBudget` (#0272 items 1–2).
    ///
    /// Gated by `BrokerConnectionSignalAdmission` first: `generation` is the
    /// connection this signal is *about*, which may not be the connection
    /// `brokerConnection` currently points at — an orphaned connection from
    /// a previous rebuild can still signal after being superseded (#0272's
    /// defect B). Only a signal from the current connection may mutate
    /// `isRegisteredWithBroker`, the reconnect budget, or trigger a
    /// reconnect.
    private func handleBrokerSignal(_ signal: BrokerConnectionSignal, generation: UInt64) {
        guard BrokerConnectionSignalAdmission.isCurrent(signalGeneration: generation, currentGeneration: currentBrokerGeneration) else {
            logger.notice("broker \(String(describing: signal), privacy: .public) from a superseded connection — ignoring")
            return
        }
        isRegisteredWithBroker = false
        guard reconnectBudget.consumeAttempt() else {
            logger.error("broker \(String(describing: signal), privacy: .public) — reconnect budget exhausted this launch, not retrying automatically (a future CLI call may still recover it)")
            return
        }
        switch BrokerConnectionLifecycle.response(for: signal) {
        case .retryOverExistingConnection:
            logger.notice("broker connection interrupted — peer died, retrying registration on the existing connection")
            guard let connection = brokerConnection, let endpoint = listenerEndpoint else { return }
            registerEndpoint(endpoint, over: connection, generation: generation)
        case .rebuildConnection:
            logger.error("broker connection invalidated — discarding it and building a new one")
            brokerConnection = nil
            currentBrokerGeneration = nil
            guard let endpoint = listenerEndpoint else { return }
            connectToBroker(endpoint: endpoint)
        }
    }

    /// Driven only by a genuinely failed call (the error handler on
    /// `remoteObjectProxyWithErrorHandler`, or a nil proxy) — never by
    /// `SMAppService.status`, which can report `.enabled` while launchd has
    /// no such service (#0272 item 7). Identity-gated for the same reason as
    /// `handleBrokerSignal`.
    private func handleBrokerCallFailure(_ message: String, generation: UInt64) {
        guard BrokerConnectionSignalAdmission.isCurrent(signalGeneration: generation, currentGeneration: currentBrokerGeneration) else {
            logger.notice("broker call failure from a superseded connection — ignoring (\(message, privacy: .public))")
            return
        }
        isRegisteredWithBroker = false
        logger.error("\(message, privacy: .public)")
        attemptRepairIfNeeded()
    }

    /// The `SMAppService` repair path: unregister then register, guarded to
    /// run once per launch. Only attempted when `SMAppService` itself
    /// currently claims `.enabled` — that is precisely the wedged state this
    /// repairs (`.status` says registered, launchd disagrees). A
    /// `.notRegistered`/`.requiresApproval` state means the user has not
    /// opted in (or hasn't approved yet), and silently calling `register()`
    /// there would be an unrequested enrollment — that stays the deliberate,
    /// user-initiated action in `SettingsView` (#0270).
    ///
    /// Failure mode worth recording: if `.status` reports
    /// `.notRegistered`/`.notFound` while the user *had* previously
    /// enrolled — #0270 notes this happens when the app bundle moves, since
    /// `SMAppService` state is keyed to the bundle path — this filter skips
    /// repair entirely and the user must re-register from `SettingsView`.
    /// Defensible (silently registering an agent the user never opted in to
    /// from this exact bundle location would be worse), but it is a real
    /// gap, not a false alarm; `.requiresApproval` similarly produces only a
    /// log line here, no user-facing nudge — `SettingsView` remains the
    /// only place either state is surfaced to the user.
    private func attemptRepairIfNeeded() {
        brokerAgentController.refresh()
        guard brokerAgentController.state == .enabled else {
            logger.notice("attemptRepairIfNeeded: SMAppService state is \(String(describing: self.brokerAgentController.state), privacy: .public), not .enabled — not a wedged-registration case, skipping repair")
            return
        }
        guard repairGuard.attemptRepair() else {
            logger.notice("broker repair already attempted this launch — not retrying")
            return
        }
        logger.notice("SMAppService reports enabled but the broker call failed — repairing registration (unregister, then register)")
        // Discard the failing connection before rebuilding rather than
        // overwriting `brokerConnection` in place — leaving the old one
        // resumed-but-orphaned was #0272's defect B: it could still signal
        // later and clobber the new connection's state. Clearing
        // `currentBrokerGeneration` first means that late signal is dropped
        // as stale by `BrokerConnectionSignalAdmission` regardless of
        // exactly when `invalidate()`'s handler fires — and unlike an
        // address-derived id, a later generation number can never
        // accidentally equal this one.
        currentBrokerGeneration = nil
        brokerConnection?.invalidate()
        brokerConnection = nil
        brokerAgentController.unregister()
        brokerAgentController.register()
        logger.notice("repair complete — SMAppService state now \(String(describing: self.brokerAgentController.state), privacy: .public); retrying broker connection")
        if let endpoint = listenerEndpoint {
            connectToBroker(endpoint: endpoint)
        }
    }
}
