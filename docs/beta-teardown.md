# Removing a Beta install

`#0279` gave the Beta build its own bundle identifier (`co.sstools.Batty.beta`),
product name (`Batty Beta.app`), LaunchAgent, CLI install path
(`/usr/local/bin/batty-beta`), and Application Support directory
(`~/Library/Application Support/Batty Beta`) — fully separate from Prod's
`/Applications/Batty.app`. This page is the reverse of `scripts/build-beta.sh`:
how to remove a Beta install cleanly once you're done testing it.

`scripts/build-beta.sh --teardown` prints the same steps below without
performing any of them — read them here, run them yourself.

## Why the order matters

`#0270` found that leftover `SMAppService` registration state, keyed to a
bundle identifier whose bundle no longer exists on disk, is exactly what
wedges launchd. Recovery from a wedged state is expensive: `sfltool
resetbtm` plus a reboot. Two variants of the same app installed side by
side — Prod running continuously, Beta installed and removed repeatedly
while testing — is precisely the scenario that produces this if the
LaunchAgent isn't unregistered *before* the bundle is deleted.

**Always unregister the LaunchAgent before removing the app bundle.**

## Steps, in order

1. **Quit Batty Beta**, if it's running. Prod is unaffected either way —
   the two variants share no launch, process, or window state.

2. **Unregister the Beta LaunchAgent before deleting anything.**
   - System Settings → General → Login Items & Extensions → "Allow in the
     Background" → find **Batty Beta** → turn it off. This calls
     `SMAppService.unregister()` for Beta's broker agent
     (`co.sstools.Batty.beta.broker`) without touching Prod's
     (`co.sstools.Batty.broker`) — the two are independent services with
     independent Login Items entries by design (`#0277`).
   - Batty's own Settings window also surfaces broker registration state
     if you'd rather unregister from there.

3. **Remove the app:**
   ```sh
   rm -rf "/Applications/Batty Beta.app"
   ```

4. **Remove the CLI symlink** (installed separately from the app, and not
   cleaned up by deleting the bundle):
   ```sh
   rm -f /usr/local/bin/batty-beta
   ```

5. **Remove Beta's Application Support directory** — the session-name
   cache (`#0279` leak 1) and, once `#0221` lands, any restored workspace
   state:
   ```sh
   rm -rf "$HOME/Library/Application Support/Batty Beta"
   ```

6. **Optional — clear Beta's `UserDefaults`:**
   ```sh
   defaults delete co.sstools.Batty.beta
   ```

7. **Optional — remove Beta's saved window state and caches** (review
   round 1 addition; neither is load-bearing for a clean reinstall, but
   both are otherwise-orphaned per-bundle-id state once the app is gone):
   ```sh
   rm -rf "$HOME/Library/Saved Application State/co.sstools.Batty.beta.savedState"
   rm -rf "$HOME/Library/Caches/co.sstools.Batty.beta"
   ```

## What this does *not* touch

Every one of the above is scoped to `co.sstools.Batty.beta` / `Batty
Beta.app` / `batty-beta`. Prod's bundle (`/Applications/Batty.app`), its
broker (`co.sstools.Batty.broker`), its CLI (`/usr/local/bin/batty`), its
Application Support directory (`~/Library/Application Support/Batty`), and
its `UserDefaults` domain (`co.sstools.Batty`) are untouched — the two
variants were made to not share state for exactly this reason.

## Reinstalling later

Removing everything above is a clean slate — a subsequent
`scripts/build-beta.sh` + copy-to-`/Applications` starts Beta fresh, with
no leftover cache entries or stale LaunchAgent registration to conflict
with the new install.
