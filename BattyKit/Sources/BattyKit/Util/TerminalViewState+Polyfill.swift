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
/// **This is now a Swift-wrapper gap, not a C-API gap** (#0398, verified
/// against the pin `#0389` moved to, `a2565cc`): the shipped xcframework's
/// `ghostty.h` already declares `ghostty_surface_needs_confirm_quit` and
/// `ghostty_surface_process_exited` — the very symbols this polyfill was
/// always meant to be temporary cover for. `grep -rn "needsConfirmClose\|
/// needs_confirm\|process_exited" Sources/` over the `libghostty-spm`
/// checkout still returns zero hits: the C functions exist, nothing in the
/// Swift layer calls them yet, and no handle escapes for Batty to call them
/// itself (`TerminalSurface.rawValue` / `TerminalController.app` are both
/// `internal`). So the fix is a small upstream Swift addition, not a wait
/// on Ghostty itself.
///
/// Behavioral implication: while these polyfills are in effect, the
/// busy-aware close-tab confirmation in `#0054` always treats every tab
/// as idle. Cmd-W on a tab running `sleep 30` closes silently — the
/// confirmation dialog never fires. Plumbing is intact; the signal is
/// absent. `TabRuntime.needsConfirmCloseOverride` (#0398) makes the
/// confirmation *branches* unit-testable without touching this file — it's
/// a test seam one layer up, not a fix to the signal this polyfill stubs.
///
/// Remove this file once the fork exposes the real properties. Building
/// against a future fork that declares `needsConfirmClose` /
/// `processExited` natively will result in a duplicate-member error
/// here — that's the cue to delete the polyfill.
public extension TerminalViewState {
    var needsConfirmClose: Bool { false }
    var processExited: Bool { false }
}
