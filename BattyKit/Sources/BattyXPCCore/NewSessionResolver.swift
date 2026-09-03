// NewSessionResolver.swift

import Foundation

/// Finds the Session `batty new <path>` just created, given a topology
/// snapshot taken before the `batty://` dispatch and a later snapshot from
/// the post-dispatch poll (#0380).
///
/// Path alone cannot identify the new Session — the user may already have
/// one open on the same directory — so a Session only qualifies when its
/// `path` matches **and** its `id` was not present in `before`. That is why
/// the snapshot has to be taken *before* dispatch: matching against a
/// snapshot taken after would let a pre-existing Session on the same path
/// pass the check.
///
/// Pulled out of the CLI target (`batty`) the same way `BoundedPoll` was
/// pulled out of any XPC type: it needs only `TopologyPayload`
/// (`BattyXPCCore`), so it is unit-testable with two literal payloads and no
/// XPC connection, endpoint, or running app involved.
public nonisolated enum NewSessionResolver {
    /// `path` should be the same resolved absolute path used to build the
    /// `batty://` URL (`resolvePath`/`SessionURLBuilder.resolve`), not the
    /// caller's raw argument. It does **not**, however, need to be
    /// symlink-resolved the way `TopologySessionPayload.path` ends up being
    /// — see `normalizedForComparison` below for why the two sides can
    /// disagree on that axis and why this function corrects for it itself
    /// rather than requiring the caller to.
    ///
    /// `TopologySessionPayload.path` is `nil` until it resolves, so a new
    /// Session can appear in `after` before its path does. Such a Session
    /// is skipped, not treated as a match failure that stops the search —
    /// the caller keeps polling until either a real match appears or the
    /// bound expires, rather than returning the wrong Session or crashing
    /// on a `nil` compare.
    ///
    /// When more than one Session in `after` qualifies, the first one
    /// encountered in `after.windows` order wins — the same "first match
    /// wins" contract the shell workaround's `jq first(...)` expression
    /// had. Prefer `findNewSessions(before:after:path:)` at any call site
    /// that can act on ambiguity instead of silently picking one: round 3
    /// review (#0380) found that a cold launch can make more than one
    /// Session qualify for real (not just the "two agents raced" case this
    /// comment used to name as the only way in) — see that function's doc
    /// comment. This single-match form still exists for the (structurally
    /// impossible in `NewSessionCommand`'s own callers, but not in
    /// principle) case where a caller has already ruled out ambiguity, and
    /// so it can afford to trust "first wins".
    public static func findNewSession(before: TopologyPayload, after: TopologyPayload, path: String) -> NewSessionMatch? {
        findNewSessions(before: before, after: after, path: path).first
    }

    /// Same matching rule as `findNewSession(before:after:path:)` — `path`
    /// equal and `id` not in `before` — but returns **every** qualifying
    /// Session in `after.windows` order instead of just the first, so a
    /// caller can detect ambiguity instead of guessing.
    ///
    /// This is not only the "two agents raced on the same path"
    /// possibility the original doc comment named: `NewSessionCommand`'s
    /// cold-launch path (#0380 round 3 review, B1) snapshots an
    /// intentionally empty `before` (nothing can predate a launch that
    /// hasn't happened yet), but a cold launch creates **two** Sessions,
    /// not one — `Session 1` at `$HOME` (`WindowRuntime.init`) plus the
    /// requested path's Session (`docs/batty-cli-install.md`'s end-to-end
    /// trace documents this as accepted behavior, #0251, not a bug). If the
    /// requested path *is* `$HOME` (`batty ~`, `batty $HOME`, bare `batty`/
    /// `batty .` run from home — "the interactive `batty .` habit" the
    /// issue names), both Sessions can satisfy "path equal and id not in
    /// `before`" **simultaneously** — both visible in the same `list`
    /// response with resolved paths — and this function correctly returns
    /// both rather than picking one. A caller polling for exactly one new
    /// Session should keep polling (not guess) while this returns more
    /// than one, and report the ambiguity explicitly if it never resolves
    /// to exactly one before the bound.
    ///
    /// **What this does not close (#0380 round 4 review, B1):** the two
    /// Sessions' paths need not resolve *together*. `Session 1`'s OSC 7
    /// report can land — making it, alone, a "path matches and id is new"
    /// match — before the `batty://` URL is even delivered to
    /// `BattyURLHandler` (Apple Event ordering relative to broker
    /// registration and shell startup is not guaranteed), or the URL can
    /// be dropped entirely (`AppStateStore.addSession` returns `nil` when
    /// no window is registered yet, #0251). In either case `after` contains
    /// only `Session 1`, `matches.count == 1`, and the caller receives
    /// `Session 1`'s id with no ambiguity signal — the original defect,
    /// just narrowed to a smaller and more specific window than before this
    /// function existed. See `issues/0380.md`'s pinned decision and
    /// `## Gotchas` for why this is accepted rather than fixed here.
    public static func findNewSessions(before: TopologyPayload, after: TopologyPayload, path: String) -> [NewSessionMatch] {
        let priorSessionIDs = Set(before.windows.flatMap { $0.sessions.map(\.id) })
        let normalizedQueryPath = normalizedForComparison(path)
        var matches: [NewSessionMatch] = []
        for window in after.windows {
            for session in window.sessions {
                guard let sessionPath = session.path else { continue }
                guard normalizedForComparison(sessionPath) == normalizedQueryPath else { continue }
                guard !priorSessionIDs.contains(session.id) else { continue }
                matches.append(NewSessionMatch(sessionID: session.id, paneID: session.focusedPaneID))
            }
        }
        return matches
    }

    /// `SessionURLBuilder.resolve` standardizes the CLI's path but does
    /// **not** resolve symlinks. The Session's own `path`, though, is
    /// eventually overwritten by `syncWorkingDirectoryFromTerminal()` from
    /// libghostty's OSC 7 report — which is `getcwd()`, fully
    /// symlink-resolved. `/tmp`, `/var`, and `/etc` are all symlinks into
    /// `/private` on macOS (and `mktemp -d` lands under `/var/folders/…`),
    /// so `batty new /tmp/foo` would otherwise compare `/tmp/foo` against
    /// `/private/tmp/foo` and never match — a race against how fast the
    /// shell reports its real cwd, not a deterministic miss. Resolving both
    /// sides here (comparison only — the caller's own path/URL is
    /// untouched) makes the match symlink-invariant regardless of which
    /// side of that race wins.
    ///
    /// `URL(fileURLWithPath:)`'s no-`isDirectory:` initializer stats the
    /// path to decide whether to append a trailing slash, and
    /// `resolvingSymlinksInPath()` carries that flag through unchanged — it
    /// does not add or remove a trailing slash of its own. So when the
    /// path's *final component* is itself a symlink (`/tmp`, `/etc` — not a
    /// subdirectory reached through one, like `/tmp/foo`), the unresolved
    /// spelling stats the symlink itself (not a directory, per that
    /// initializer's own stat) and gets no slash, while the resolved
    /// spelling stats the real directory underneath and gets one — leaving
    /// the two sides one trailing slash apart even after resolving symlinks.
    /// `URL(fileURLWithPath:isDirectory:true)` skips the stat entirely and
    /// always appends the slash, so both sides agree regardless of which
    /// one names the symlink.
    private static func normalizedForComparison(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path(percentEncoded: false)
    }
}

/// `batty new`'s answer, once found: the new Session's id and its
/// `focusedPaneID` — the caller's next split/mutation target, which is also
/// why `pane split` does not need a `--session` flag (#0380's Relation
/// note). This is CLI-printed output, not a value that crosses XPC, but it
/// lives next to `NewSessionResolver.findNewSession(before:after:path:)`
/// (not `BattyCLICore`) since that's the only place that builds one.
public nonisolated struct NewSessionMatch: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let paneID: UUID

    public init(sessionID: UUID, paneID: UUID) {
        self.sessionID = sessionID
        self.paneID = paneID
    }
}
