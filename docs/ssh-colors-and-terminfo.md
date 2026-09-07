# SSH, `COLORTERM`, terminfo, and Themes

Why colours look different over `ssh`, what Batty's `shell-integration-features`
config key does and does not do today, and what actually fixes a washed-out
remote `nvim`. Written for #0392, sourced from a user research note
(`issues/0392/ghostty-colorterm-ssh.md`) written while debugging exactly that.

## The thing worth knowing first

**`COLORTERM` does not carry your theme.** It is a single word — `truecolor`
or `24bit` — and it answers exactly one question: *may I send 24-bit colour?*
It says nothing about which colours, and there is no environment variable
that does.

Four separate mechanisms exist, and the third is the one that actually
carries a Theme to a remote host:

| What you want | How it travels | What it needs |
|---|---|---|
| "This terminal can do 16 million colours" | `COLORTERM` env var | `SendEnv` on the client, `AcceptEnv` on the server |
| "This terminal can do italics/graphics/…" | `TERM` + a terminfo entry | the entry installed on the remote host |
| **"Use *my* colours"** | **ANSI indices 0–15, resolved by the terminal** | the remote app must emit indices, not RGB |
| "What colour is the background?" | OSC 10/11 query, answered live | app support (neovim has it) |

### Using the theme's colours over SSH

When an app emits **ANSI colour indices 0–15**, Batty resolves each one
through the active Theme's palette at render time — change the Theme and
every running remote app recolours instantly, with nothing to sync and no
reconnect. When an app emits **24-bit RGB** instead, Batty draws exactly
those values and the Theme is ignored — the app's own palette wins.

So "use my theme in nvim over SSH" means **turning `termguicolors` off**, not
on:

```lua
vim.o.termguicolors = false   -- send indices 0-15, let Batty resolve them
vim.cmd.colorscheme("vim")    -- a scheme that mostly stays inside 0-15
```

`vim` is the base to start from — most other bundled colorschemes
(`habamax`, `retrobox`, `quiet`, `industry`, …) reach outside the 16-colour
palette for most of their highlight groups and render identically no matter
how the terminal is themed, defeating the point.

**OSC 10/11** is a fourth, narrower route: an app can *ask* the terminal what
its live foreground/background colour is (neovim supports this) rather than
relying on ANSI indices. Batty doesn't build anything specific to it; it's
named here so the trade-off is complete.

## What `shell-integration-features` controls, and what Batty sets

libghostty's `shell-integration-features` config key is a feature list. The
shipped default (`ShellIntegrationFeatures` in the pinned Ghostty source,
`src/config/Config.zig`) is:

```
cursor: true, sudo: false, title: true, ssh-env: false, ssh-terminfo: false, path: true
```

— i.e. `shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path`.
Batty never emitted this key at all before #0392, so it always inherited
that default. As of #0392, `TabRuntime.applyShellAndAppearancePreferences`
and `AppStateStore.applyAppearanceToAllSurfaces` both emit:

```
shell-integration-features = ssh-env
```

turning only `ssh-env` on. Per the pinned Ghostty source's own doc comment
for the key, an omitted feature keeps its default value — "If you omit a
feature, its default value is used, so you must explicitly disable features
you don't want" — so `ssh-env` alone is a complete, minimal statement of
intent; every other feature (`cursor`, `no-sudo`, `title`, `no-ssh-terminfo`,
`path`) stays at its default by omission rather than being spelled out
redundantly. That minimalism matters beyond style: a `shell-integration-features`
value libghostty can't parse doesn't just drop that one feature, it drops
the *entire* config the surface was built with — `keybind = clear`,
`cmd+c=copy_to_clipboard`, `env BATTY_*`, `command`, and `copy-on-select`
all went with it in testing when one token was deliberately misspelled.
Every extra token in this literal is a future pin bump's chance to reject
the whole thing over a feature name Batty doesn't even care about the
default of.

`ssh-terminfo` is deliberately **left off** rather than turned on alongside
`ssh-env`. Per the pinned Ghostty source's own doc comment, `ssh-terminfo`
"attempts to install Ghostty's embedded terminfo entry using `tic` on local
cache misses" — concretely, on the *remote* host, via a piped
`infocmp | tic` that writes into `~/.terminfo` there. That's a filesystem
write on a machine the user may not own, made without a Setting, a prompt,
or any Help disclosure — the kind of decision #0392 was explicitly told not
to make unilaterally. `ssh-env` alone carries no such cost: it is pure
client-side `-o SetEnv`/`-o SendEnv`, no remote write, no subprocess. Turning
`ssh-terminfo` on is left to whoever picks up the follow-up ticket
(**#0399**), which should present the trade-off to the user rather than
deciding it in code.

`shell-integration-features` is consumed once, at process spawn
(`termio.Exec.init`) — reapplying it to an already-running surface (as
`applyAppearanceToAllSurfaces` does on every appearance change) cannot
change a shell that already started. **The value only takes effect for Tabs
created after it's set.** If you flip a Batty setting that touches this and
an already-open SSH session doesn't change, that's expected — open a new Tab.

### This does not currently make `ssh-env`/`ssh-terminfo` work in Batty

This is the load-bearing finding of #0392, and it corrects the issue's own
working assumption that "no new plumbing is required."

`shell-integration-features` only sets the `GHOSTTY_SHELL_FEATURES`
environment variable for the spawned shell (confirmed in the pinned Ghostty
source, `src/termio/shell_integration.zig`'s `setupFeatures`). Whether
`ssh-env`/`ssh-terminfo` actually *do* anything is entirely up to the shell
integration script that gets sourced into that shell — and Batty's is not
upstream Ghostty's.

Batty links `libghostty-spm` (pinned at commit `a2565ccf…`, wrapping Ghostty
ref `c4e16970a…`). That package's `GhosttyTerminal` module bundles its own
bash/zsh integration scripts as Swift package resources
(`Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/{bash,zsh}`),
and unconditionally points libghostty at them:
`GhosttyRuntimeResources.configureEnvironment()`, called once from
`TerminalController.swift`'s `initializeRuntimeIfNeeded()`, does
`setenv("GHOSTTY_RESOURCES_DIR", <package's own bundle path>, 1)` for the
whole app process before `ghostty_init` ever runs. Nothing in Batty
overrides `GHOSTTY_RESOURCES_DIR` afterward, so this is authoritative for
the app's entire lifetime.

Those bundled scripts are a **from-scratch MIT rewrite**, not a copy of
upstream Ghostty's (GPLv3) shell integration. Their own header comments say
so directly — from `Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/zsh/ghostty-integration`:

> Features come from GHOSTTY_SHELL_FEATURES, a comma-separated list the
> terminal exports (`cursor`, `cursor:blink`, `cursor:steady`, `title`, …).
> Anything else in the list is ignored; sudo, ssh-\* and path need a ghostty
> binary or change the user's environment, and this integration does
> neither.

Concretely: the bash script never defines an `ssh` wrapper function at all.
Setting `ssh-env`/`ssh-terminfo` puts those tokens into
`GHOSTTY_SHELL_FEATURES`, and the running shell simply ignores them. Plain
`ssh` runs unmodified — no `-o SetEnv`, no `-o SendEnv`, no terminfo install.
**The config change is real (verified below) but currently inert for the
SSH-specific behavior it names**, kept because it correctly declares
Batty's intent against libghostty's config model and costs nothing; it will
start working the day `libghostty-spm`'s shell integration implements those
features, with no further Batty change needed.

Batty's own vendored copy at `Resources/ghostty-runtime/ghostty/shell-integration/`
(bundled into `Batty.app/Contents/Resources/ghostty/shell-integration/` by
`scripts/bundle-ghostty-resources.sh`) *does* contain a working, upstream-style
`ssh()` wrapper for bash, zsh, fish, elvish, and nushell (manual
`SetEnv`/`SendEnv` plus an `infocmp | tic` install over a `ControlMaster`
connection) — but it is dead code at runtime. `GHOSTTY_RESOURCES_DIR` always
points at the SPM package's own bundle instead, so this vendored tree is
never sourced. Don't assume its presence in the built app means it's live;
it isn't.

### This is a regression, not a standing gap

Worth stating plainly, because it changes how this reads: Batty had working
SSH colours and terminfo installation, and fish/elvish/nushell shell
integration, **before** the `libghostty-spm` re-pin in #0389. The previous
pin (`b146b73a…`) shipped no bundled `Resources/` and had no
`GhosttyRuntimeResources` type at all — nothing set `GHOSTTY_RESOURCES_DIR`
— so libghostty's own sentinel search (`src/os/resourcesdir.zig`, which
climbs from the executable looking for a `Contents/Resources/` containing
`terminfo/78/xterm-ghostty`) found **Batty's own vendored** five-shell tree
and used it. #0389's re-pin introduced `GhosttyRuntimeResources.configureEnvironment()`,
which sets `GHOSTTY_RESOURCES_DIR` to the package's own bundle before
`ghostty_init` runs, so the sentinel search never gets a chance to run and
Batty's vendored tree — full working `ssh()` wrappers included — became dead
weight. This is "a capability the re-pin silently removed," not "a
capability Batty never had."

### The cheapest fix candidate, if this is worth doing without waiting on upstream

Waiting for `libghostty-spm` to grow real `ssh-env`/`ssh-terminfo` support is
not the only path. Batty already bundles a *working* `ssh()` wrapper and
matching terminfo entry, in exactly the sibling layout libghostty expects
(`Contents/Resources/ghostty/shell-integration/…` next to
`Contents/Resources/terminfo/78/xterm-ghostty`) — the paragraph above. But
**there is no Batty-side env write that activates it.** The package's call
chain is `TerminalController.init` → `initializeRuntimeIfNeeded()`, a
private, once-guarded method whose body is
`GhosttyRuntimeResources.configureEnvironment()` (a `setenv(…, overwrite: 1)`)
immediately followed by `ghostty_init(0, nil)` — two adjacent lines inside
one method Batty cannot get between — and libghostty snapshots the
resources dir *during* `ghostty_init` (`src/global.zig:221`,
`resourcesdir.zig:52`, env-var-first in release mode; the xcframework ships
`ReleaseFast`). Setting `GHOSTTY_RESOURCES_DIR` before that call gets
clobbered by the package's own `setenv`; setting it after is too late — the
snapshot already happened. **Activating the vendored tree needs a one-line
change in the fork (or the pinned package) or bundle surgery, not a
Batty-side environment write.**

This is the name-worthy candidate for the follow-up ticket (**#0399**), not
an implementation detail to slip in quietly, because of the caveats that
come with it once it's a real code change rather than a one-liner:

- **It's a change to package internals**, either in the user's own fork
  (`~/Developer/brennanMKE/libghostty-spm`, already how Batty consumes the
  package — a one-line change there to honor a pre-set
  `GHOSTTY_RESOURCES_DIR`, i.e. `setenv(…, overwrite: 0)`, would do it) or
  upstream at `Lakr233/libghostty-spm`. Either way, a future pin bump has to
  preserve whatever hook gets added.
- **The vendored scripts are GPLv3**, not MIT (`Help/09-third-party-licenses.md`
  documents this in detail). Activating them at runtime in a proprietary,
  notarized macOS app is a licensing decision for the user to make, not
  something to fold into an "implementation detail." *(Whether the
  package's rewrite exists specifically to purge GPLv3 content is a
  reasonable guess, not a confirmed fact — see the hedge below.)*
- **`+ssh-cache` still won't work.** Batty ships no `ghostty` binary
  (`Batty.app/Contents/Resources/bin/` holds only `batty` and
  `BattyBroker`), so the wrapper's cache-check branch always misses and
  falls through to the install path on every `ssh` invocation — one extra
  `ControlMaster` round-trip per connection, forever. Harmless but not free.

*Hedge, not fact, on the GPLv3-purge motive:* it's tempting to read the
package's MIT rewrite as a deliberate GPLv3 purge — the dropped features
(`sudo`, `ssh-*`, `path`) are exactly the ones whose upstream implementation
touches the GPLv3, Kitty-derived `ghostty.bash`/`ghostty-integration` — but
this could not be confirmed from this environment. Upstream Ghostty at the
pinned ref still ships all five shells with their GPLv3 bash/zsh headers
intact, so the rewrite is a `libghostty-spm`-package-level decision, not
something forced by an upstream change. Treat the purge motive as a
plausible guess, not settled fact.

### A dead end, corrected — the native `+ssh` action is present, exported, and still unreachable

The static `libghostty.a` does contain a native Zig `+ssh` action —
`strings` on the binary shows `ControlMaster=yes`, `SendEnv=COLORTERM`, and
`mkdir -p ~/.terminfo … tic -x -` fragments consistent with Ghostty's own
CLI action for this. And `ghostty.h` **does** export a CLI entrypoint:
`GHOSTTY_API void ghostty_cli_try_action(void)` (`ghostty.h:1148`) — an
earlier pass over this doc claimed no such entrypoint exists; that was
wrong. It's still unreachable from Batty as pinned, for a different reason:
the action is detected from the argv handed to `ghostty_init`
(`src/main_c.zig`, `src/global.zig`), the package hardcodes
`ghostty_init(0, nil)`, and when an action *is* present,
`ghostty_cli_try_action` never returns — it runs the action and calls
`exit`. Reaching it means shipping something that behaves as a `ghostty`
CLI binary and re-plumbing the package's init call. Out of proportion for
this feature; not worth chasing further.

### What actually gets `COLORTERM` and terminfo to a remote host today

Until `libghostty-spm`'s shell integration grows real `ssh-env`/
`ssh-terminfo` support (or Batty ships an equivalent of its own — a real
code change, not a config line, and a candidate for a follow-up issue), the
working recipe is the same one the source research note already used:

**Client-side, once, in `~/.ssh/config`:**

```sshconfig
Host *
    SendEnv COLORTERM NO_COLOR
```

Placement in the file doesn't matter for `SendEnv` itself — unlike most
`ssh_config` keywords, where the first matching block wins, `SendEnv`
accumulates across every `Host` block that matches, so a `Host *` catch-all
here combines with, rather than getting overridden by, any per-host
`SendEnv` line elsewhere in the file. The remote's `sshd_config` must list
the variable in `AcceptEnv` (e.g. `AcceptEnv LANG LC_* COLORTERM NO_COLOR`);
a host that doesn't simply ignores it, no error.

**Per remote host, once, for terminfo:**

```bash
infocmp -x xterm-ghostty | ssh <host> tic -x - -o ~/.terminfo    # per-user, no sudo
# or, system-wide:
infocmp -x xterm-ghostty | ssh <host> sudo tic -x -o /usr/share/terminfo -
```

The entry `infocmp -x xterm-ghostty` reads locally is **not** the one at
`Batty.app/Contents/Resources/terminfo/78/xterm-ghostty` that
`scripts/bundle-ghostty-resources.sh`/`scripts/preflight.sh` bundle and
guard — that copy is dead weight for the same `GHOSTTY_RESOURCES_DIR`
reason as the shell-integration scripts above. The live one is
`libghostty-spm`'s own `Sources/GhosttyTerminal/Resources/terminfo/78/xterm-ghostty`,
derived by the pinned Ghostty source (`src/termio/Exec.zig`) as the
directory adjacent to `GHOSTTY_RESOURCES_DIR`. Both files declare a functionally
equivalent `xterm-ghostty` entry (`infocmp -x` diff shows one trivial
capability drift, `Se=\E[2 q` vs `\E[0 q`, from the two copies being vendored
at slightly different points in time), so this doesn't change what a user
sees — but it means the `#0003` bundling/preflight guard is verifying a copy
the running app never reads. Nothing here needs network access beyond the `ssh`
invocation itself.

### What Batty already sets locally, unconditionally

Independent of `shell-integration-features` entirely: libghostty's
`termio.Exec.init` sets `TERM` and `COLORTERM=truecolor` unconditionally on
every spawned local shell (source: `src/termio/Exec.zig`) — Batty never
overrides the `term` config key, so `TERM` is the pinned Ghostty default. A
resources directory being available only gates *which* value `TERM` gets
(`xterm-ghostty` when found, `xterm-256color` as a logged fallback when not)
and whether `TERMINFO` also gets exported (pointing at the terminfo directory
adjacent to the resources dir) — `COLORTERM` is set to `truecolor` in both
branches either way. That's why a local Batty Tab already reports
`COLORTERM=truecolor` — the gap this doc is about is entirely about what
survives the *SSH hop*, not what Batty sets locally.
This is a source-level conclusion; confirm the live values with
`echo $TERM; echo $COLORTERM` in an actual Batty Tab, since #0392's
implementing environment could not launch the app to check.

## Summary for anyone about to touch this again

- **This is a regression, not a standing gap.** Before the `libghostty-spm`
  re-pin in #0389, Batty's own vendored five-shell tree (bash/zsh/fish/
  elvish/nushell, working `ssh()` wrappers included) was the one libghostty
  actually sourced. The re-pin's `GhosttyRuntimeResources.configureEnvironment()`
  redirected `GHOSTTY_RESOURCES_DIR` at the package's own bash/zsh-only,
  MIT-rewrite bundle and orphaned it. SSH colours and fish/nushell
  integration worked before #0389 and stopped because of it.
- Enabling `shell-integration-features = ssh-env` in Batty's config is
  correct and harmless, but currently a no-op for the behavior it names —
  the shell-integration scripts that would act on it don't exist in the
  pinned dependency. `ssh-terminfo` is deliberately left off; it writes to
  the remote host's `~/.terminfo` and that trade-off is for the follow-up
  ticket (**#0399**) to decide, not this one.
- **The candidate worth naming if this is going to get fixed for real:**
  activate Batty's own already-bundled, already-working `ssh()` wrapper +
  terminfo tree (bash/zsh/fish/elvish/nushell) via a one-line change in the
  fork (or the pinned package) that honors a pre-set `GHOSTTY_RESOURCES_DIR`
  — **not** a Batty-side `setenv` call, which cannot win the ordering race
  against the package's own `configureEnvironment()` → `ghostty_init` call.
  See "The cheapest fix candidate" above for why, and for the
  package-internals, GPLv3 (motive unconfirmed — see the hedge above), and
  `+ssh-cache` caveats that come with it. Tracked in **#0399**;
  fish/elvish/nushell losing shell integration entirely is the related but
  separate **#0400**.
- The Theme-follows-you-over-SSH behavior (ANSI indices 0–15) already works
  today and needs no code change — it's a property of how Batty resolves
  colours locally, not something that has to survive the SSH hop.
- Getting `COLORTERM` and a resolvable `TERM` to a remote host today
  requires the user's own `~/.ssh/config` `SendEnv` line and a one-time
  `tic` install per host — Batty automates neither yet.
