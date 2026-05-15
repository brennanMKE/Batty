// TerminalViewState+Polyfill.swift

import GhosttyTerminal

/// Polyfills for surface-lifecycle predicates that the upstream
/// `libghostty-spm` fork at `batty-delegates` does not yet expose.
///
/// `#0054`'s implementation (commit `905d533`) was authored against a
/// fork-side change (intended commit `8915065`) that exposes
/// `ghostty_surface_needs_confirm_quit` and `ghostty_surface_process_exited`
/// as Swift properties on `TerminalViewState`. That fork commit was not
/// pushed; only Batty's changes landed. To make Batty compile against
/// the public fork HEAD (`ef88eed`) until the upstream side ships,
/// stub both predicates as `false`.
///
/// Behavioral implication: while these polyfills are in effect, the
/// busy-aware close-tab confirmation in `#0054` always treats every tab
/// as idle. Cmd-W on a tab running `sleep 30` closes silently — the
/// confirmation dialog never fires. Plumbing is intact; the signal is
/// absent.
///
/// Remove this file once the fork exposes the real properties. Building
/// against a future fork that declares `needsConfirmClose` /
/// `processExited` natively will result in a duplicate-member error
/// here — that's the cue to delete the polyfill.
public extension TerminalViewState {
    var needsConfirmClose: Bool { false }
    var processExited: Bool { false }
}
