// AppBundleResolution.swift

import Foundation

/// Which on-disk app bundle the CLI should target, derived deterministically
/// rather than via `open -b <bundle-id>` / `NSRunningApplication
/// .runningApplications(withBundleIdentifier:)` — both delegate to
/// LaunchServices' own bundle-identifier resolution, and #0361 found **eight
/// distinct bundles** claiming `co.sstools.Batty` on one machine (several
/// DerivedData debug builds, two stale unmounted-DMG registrations, and the
/// one actually installed at `/Applications/Batty.app`). Any decision keyed
/// only on the identifier — "is the app running?", "which app do I launch?"
/// — can silently pick the wrong one of those eight.
///
/// The embedded CLI copy (`Contents/Resources/bin/batty`, always that literal
/// path regardless of variant — see `CLIInstaller.bundledCLIPath`) sits
/// *inside* the exact bundle it should target, and `CLIInstaller.install()`
/// symlinks `/usr/local/bin/batty` straight to that embedded copy. So
/// resolving symlinks on the CLI's own executable path and checking for that
/// suffix identifies the target bundle with zero ambiguity — no LaunchServices
/// involved at all. Only a CLI copy that is neither the embedded binary nor a
/// symlink to it (e.g. a standalone `cp`'d copy placed on `PATH` by hand,
/// which is what #0361 found on the reporting machine) needs a fallback, and
/// that fallback is a single named path, not an OS-arbitrated lookup.
///
/// Kept as a pure function of a path string and a variant — no
/// `FileManager`, no symlink resolution, no `NSRunningApplication` — so the
/// branch is unit-testable; `AppBundleLocator` (the `batty` executable
/// target) does the real filesystem/AppKit work and calls into this.
public nonisolated enum AppBundleResolution: Sendable, Equatable {
    /// Derived directly from the CLI's own (symlink-resolved) location:
    /// unambiguous by construction.
    case derivedFromOwnLocation(bundlePath: String)
    /// The CLI's own location isn't inside, or symlinked into, any bundle —
    /// falls back to the per-variant well-known `/Applications` path. The
    /// caller must confirm this actually exists before trusting it; unlike
    /// `derivedFromOwnLocation`, it's a guess about where the app *should*
    /// be, not a fact about where this executable *is*.
    case wellKnownApplicationsFallback(bundlePath: String)

    public var bundlePath: String {
        switch self {
        case .derivedFromOwnLocation(let path), .wellKnownApplicationsFallback(let path):
            return path
        }
    }

    /// The suffix every embedded CLI copy has, regardless of variant —
    /// `CLIInstaller.bundledCLIPath` hardcodes this same literal path
    /// inside whichever variant's bundle it's embedded in.
    static let embeddedCLISuffix = "/Contents/Resources/bin/batty"

    /// `resolvedOwnExecutablePath` must already have symlinks resolved
    /// (`AppBundleLocator` does this before calling in) — this function
    /// does no filesystem access of its own.
    public static func resolve(resolvedOwnExecutablePath: String, variant: ServiceNames.Variant) -> AppBundleResolution {
        if resolvedOwnExecutablePath.hasSuffix(embeddedCLISuffix) {
            let bundlePath = String(resolvedOwnExecutablePath.dropLast(embeddedCLISuffix.count))
            if !bundlePath.isEmpty {
                return .derivedFromOwnLocation(bundlePath: bundlePath)
            }
        }
        return .wellKnownApplicationsFallback(bundlePath: variant.applicationsInstallPath)
    }
}
