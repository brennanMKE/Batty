// ServiceNames.swift

/// Single source of truth for the broker's Mach service identity, derived
/// per app variant (Prod vs Beta — #0277).
///
/// launchd will only reserve the name if four strings are byte-identical:
/// the launch-agent plist's filename, its `Label`, the `MachServices` key,
/// and the name client code connects to. Get any one of them wrong and
/// launchd *silently* declines to reserve the name — no error at install
/// time, no warning at registration, nothing in the log. It surfaces much
/// later as an unexplained "connection invalid" in the CLI (see
/// `docs/xpc/xpc-cli-architecture.md` "The four-string rule"). That rule
/// holds **per variant**: Prod's four strings must agree with each other,
/// Beta's four strings must agree with each other, and the two variants'
/// strings must never collide.
///
/// Deriving `agentLabel(for:)` and `agentPlistName(for:)` from
/// `broker(for:)` collapses three of the four to one edit per variant. The
/// fourth — the plist's `Label` *value*, hand-typed inside each variant's
/// `.plist` XML (`Configuration/co.sstools.Batty.broker.plist`,
/// `Configuration/co.sstools.Batty.beta.broker.plist`) — cannot be derived
/// from Swift source; it must be kept equal to that variant's `agentLabel`
/// by inspection (`BrokerAgentPlistTests` checks this for both files), and
/// each plist carries a comment saying so.
public nonisolated enum ServiceNames {
    /// Which shipped variant of Batty a set of derived names belongs to.
    /// Prod and Beta each get their own broker identity so both can
    /// register with launchd and be driven independently — see #0277.
    public enum Variant: Sendable, Equatable, CaseIterable {
        case prod
        case beta

        /// `PRODUCT_BUNDLE_IDENTIFIER` for this variant
        /// (`Configuration/App.xcconfig`, `Configuration/Beta.xcconfig`).
        /// Prod's value is byte-identical to the pre-#0277 literal — no
        /// migration for existing Prod installs.
        public var appBundleIdentifier: String {
            switch self {
            case .prod: "co.sstools.Batty"
            case .beta: "co.sstools.Batty.beta"
            }
        }

        /// The command name this variant's CLI installs as on `PATH`.
        /// Prod keeps the plain `batty` name unconditionally (no
        /// migration). Beta uses a distinct name — `batty-beta` — so
        /// installing from one variant can never silently repoint the
        /// other variant's symlink (#0277 "The single-batty-on-PATH
        /// problem"): both variants' `CLIInstaller` used to default to the
        /// same `/usr/local/bin/batty`, so whichever variant installed
        /// last silently owned the PATH command.
        public var cliCommandName: String {
            switch self {
            case .prod: "batty"
            case .beta: "batty-beta"
            }
        }

        /// Where this variant's "Install CLI" button symlinks into
        /// `/usr/local/bin`. See `cliCommandName`.
        public var cliInstallPath: String {
            "/usr/local/bin/\(cliCommandName)"
        }

        /// Maps a bundle identifier — typically `Bundle.main.bundleIdentifier`
        /// read at runtime by the app — back to the `Variant` it belongs
        /// to. `nil` for anything that isn't one of the two known variants;
        /// callers must fail closed rather than silently assuming Prod.
        public init?(bundleIdentifier: String?) {
            guard let bundleIdentifier else { return nil }
            switch bundleIdentifier {
            case Variant.prod.appBundleIdentifier: self = .prod
            case Variant.beta.appBundleIdentifier: self = .beta
            default: return nil
            }
        }
    }

    /// Reverse-DNS Mach service name for `variant`: what that variant's
    /// broker registers with launchd, and what that variant's client code
    /// connects to.
    public static func broker(for variant: Variant) -> String {
        "\(variant.appBundleIdentifier).broker"
    }

    /// `variant`'s launch agent plist's `Label`. Must equal `broker(for: variant)`.
    public static func agentLabel(for variant: Variant) -> String {
        broker(for: variant)
    }

    /// `variant`'s launch agent plist's filename, inside
    /// `Contents/Library/LaunchAgents/`.
    public static func agentPlistName(for variant: Variant) -> String {
        "\(agentLabel(for: variant)).plist"
    }

    /// `variant`'s app bundle identifier, for that variant's CLI to launch
    /// its own app by (`docs/xpc/xpc-cli-architecture.md` "Launching the
    /// app on demand"). Equivalent to `variant.appBundleIdentifier`,
    /// exposed here so every derived name reads from one entry point.
    public static func appBundleIdentifier(for variant: Variant) -> String {
        variant.appBundleIdentifier
    }

    /// The broker binary's path relative to the bundle root — what each
    /// variant's plist's `BundleProgram` key must contain. Not
    /// variant-dependent: both variants embed the broker at the same
    /// relative path inside their own bundle.
    public static let agentBundleProgram = "Contents/Resources/bin/BattyBroker"

    // MARK: - Baked "current" variant (bare Mach-Os only)
    //
    // `batty` and `BattyBroker` are bare Mach-Os at `Contents/Resources/bin/`
    // with no adjacent `Info.plist`, so `Bundle.main` cannot resolve which
    // variant shipped them at runtime (#0270, #0277's "bare-Mach-O
    // asymmetry"). The "Embed CLI" / "Embed Broker" build phases
    // (`Batty.xcodeproj/project.pbxproj`) pass `-Xswiftc -DBATTY_VARIANT_BETA`
    // to `swift build` when `PRODUCT_BUNDLE_IDENTIFIER` is Beta's; absent
    // that flag, Prod is assumed. `current` is the only variant-*selecting*
    // piece of this file — every derivation above stays unconditional and
    // testable for either variant regardless of how this binary was built.
    //
    // The app target never reads `current`: it always has a real
    // `Bundle.main` and derives its variant from
    // `Bundle.main.bundleIdentifier` at runtime instead
    // (`AppXPCCoordinator`, `BrokerAgentController`, `CLIInstaller`) — that
    // works today and needs no compile-time flag.
    #if BATTY_VARIANT_BETA
    public static let current: Variant = .beta
    #else
    public static let current: Variant = .prod
    #endif

    /// Reverse-DNS Mach service name: what the broker registers with
    /// launchd, and what client code connects to. Baked to `current` — see
    /// the note above.
    public static var broker: String { broker(for: current) }

    /// The launch agent plist's `Label` for `current`. Must equal `broker`.
    public static var agentLabel: String { agentLabel(for: current) }

    /// The launch agent plist's filename for `current`, inside
    /// `Contents/Library/LaunchAgents/`.
    public static var agentPlistName: String { agentPlistName(for: current) }

    /// The main app's bundle identifier for `current`, for the CLI to
    /// launch it by.
    public static var appBundleIdentifier: String { appBundleIdentifier(for: current) }
}
