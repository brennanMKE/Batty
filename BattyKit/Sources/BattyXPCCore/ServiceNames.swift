// ServiceNames.swift

/// Single source of truth for the broker's Mach service identity.
///
/// launchd will only reserve the name if four strings are byte-identical:
/// the launch-agent plist's filename, its `Label`, the `MachServices` key,
/// and the name client code connects to. Get any one of them wrong and
/// launchd *silently* declines to reserve the name — no error at install
/// time, no warning at registration, nothing in the log. It surfaces much
/// later as an unexplained "connection invalid" in the CLI (see
/// `docs/xpc/xpc-cli-architecture.md` "The four-string rule").
///
/// Deriving `agentLabel` and `agentPlistName` from `broker` collapses three
/// of the four to one edit. The fourth — the plist's `Label` *value*, which
/// must be hand-typed inside the `.plist` XML by whoever wires it up in
/// #0270 — cannot be derived from Swift source; it must be kept equal to
/// `agentLabel` by inspection, and the plist should carry a comment saying so.
public nonisolated enum ServiceNames {
    /// Reverse-DNS Mach service name: what the broker registers with
    /// launchd, and what client code connects to.
    public static let broker = "co.sstools.Batty.broker"

    /// The launch agent plist's `Label`. Must equal `broker`.
    public static let agentLabel = broker

    /// The launch agent plist's filename, inside
    /// `Contents/Library/LaunchAgents/`.
    public static let agentPlistName = "\(agentLabel).plist"

    /// The broker binary's path relative to the bundle root — what the
    /// plist's `BundleProgram` key must contain (hand-typed there, same
    /// caveat as `agentLabel`; kept as one named constant here so #0270's
    /// embedding script and any Swift call site share one source of truth
    /// instead of repeating the literal).
    public static let agentBundleProgram = "Contents/Resources/bin/BattyBroker"
}
