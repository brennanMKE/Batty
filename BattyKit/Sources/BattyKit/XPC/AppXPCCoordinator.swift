// AppXPCCoordinator.swift

import BattyXPCCore
import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "AppXPCCoordinator")

/// Owns the app-side anonymous XPC listener and its registration with the
/// broker (#0271). Created once and started from
/// `BattyAppDelegate.applicationDidFinishLaunching`.
///
/// Kept intentionally minimal per #0271's scope: registers once at launch
/// and logs the outcome. Re-registering after a broker restart, reacting to
/// `invalidationHandler` beyond logging, and the `SMAppService` repair path
/// are #0272's lifecycle hardening, not this type's.
@MainActor
public final class AppXPCCoordinator {
    public private(set) var isRegisteredWithBroker = false

    private let service = AppXPCService()
    private var listener: NSXPCListener?
    private var listenerDelegate: AppXPCListenerDelegate?
    private var brokerConnection: NSXPCConnection?

    public init() {}

    public func start() {
        // ServiceNames.broker is invariant across Prod/Beta (#0270's
        // Gotchas), so without this guard a Beta launch would connect to
        // and successfully registerAppEndpoint on *Prod's* broker whenever
        // Prod's agent happens to be registered — silently overwriting
        // Prod's stored endpoint, after which `batty status` drives Beta
        // and Prod's registration stays dead until Prod is relaunched.
        // Failing closed here converts that silent cross-process
        // corruption into an explicit, logged no-op; it forecloses nothing
        // about the eventual variant-suffixing decision #0270 left open.
        guard Bundle.main.bundleIdentifier == ServiceNames.appBundleIdentifier else {
            logger.notice("start: bundle identifier \(Bundle.main.bundleIdentifier ?? "<nil>", privacy: .public) != \(ServiceNames.appBundleIdentifier, privacy: .public) (Prod-only) — not starting the XPC listener")
            return
        }

        let listener = NSXPCListener.anonymous()
        let delegate = AppXPCListenerDelegate(exportedObject: service)
        listener.delegate = delegate
        listener.resume()
        self.listener = listener
        self.listenerDelegate = delegate
        logger.info("anonymous listener resumed")
        registerWithBroker(endpoint: listener.endpoint)
    }

    private func registerWithBroker(endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(machServiceName: ServiceNames.broker)
        connection.remoteObjectInterface = XPCInterfaces.broker
        // Every Foundation-supplied handler closure here is `@Sendable` and
        // hops back with `Task { @MainActor ... }` — the SIGTRAP trap this
        // whole child is written against (`docs/xpc/swift-concurrency-and-xpc.md`
        // #1). Skipping `@Sendable` compiles clean under strict concurrency
        // and crashes at runtime with nothing logged, because the crash is
        // inside the handler that would have logged it.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBrokerRegistrationFailure("broker connection interrupted")
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBrokerRegistrationFailure("broker connection invalidated")
            }
        }
        connection.resume()
        brokerConnection = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleBrokerRegistrationFailure("broker unreachable: \(error.localizedDescription)")
            }
        }) as? BrokerProtocol else {
            handleBrokerRegistrationFailure("failed to obtain broker proxy")
            return
        }

        // registerAppEndpoint is one-way and gives no delivery confirmation
        // — a subsequent round trip (brokerPing) is what confirms the
        // broker actually received it, never the call returning
        // (`docs/xpc/xpc-cli-architecture.md` "Confirm registration with a
        // round trip, not a return").
        proxy.registerAppEndpoint(endpoint)
        proxy.brokerPing { @Sendable [weak self] description in
            Task { @MainActor [weak self] in
                self?.isRegisteredWithBroker = true
                logger.info("endpoint registered and confirmed — \(description, privacy: .public)")
            }
        }
    }

    private func handleBrokerRegistrationFailure(_ message: String) {
        isRegisteredWithBroker = false
        logger.error("\(message, privacy: .public)")
    }
}
