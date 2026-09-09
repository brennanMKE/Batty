# Beta demo script — CLI, agentic workflows, view types

For the Beta build at `beta-build/Products/Batty Beta.app`. Everything below
uses `batty-beta`, which talks only to Batty Beta — Prod is never touched.

Nothing in this script has been run against a live app. Every step is written
from source and unit tests. Where a step is expected to fail, it says so.

## 0. Install

```sh
cp -R "beta-build/Products/Batty Beta.app" "/Applications/Batty Beta.app"
sudo ln -sf "/Applications/Batty Beta.app/Contents/Resources/bin/batty" /usr/local/bin/batty-beta
```

The build is **unsigned** (ad-hoc on the embedded CLI and broker only). On this
Mac that is fine. Copying to the MacBook will trip Gatekeeper — clear quarantine
there:

```sh
xattr -dr com.apple.quarantine "/Applications/Batty Beta.app"
```

Launch Batty Beta once from Finder. If the broker never registers, approve it in
System Settings → General → Login Items & Extensions → Allow in the Background,
or rebuild with `./build.sh package --sign`.

```sh
batty-beta ping        # expect: broker reachable
batty-beta status      # expect: pid, uptime, window/session/tab counts
```

If `ping` exits 2, the broker is not registered — fix that before continuing;
everything downstream depends on it.

## 1. The verb roster is self-describing

```sh
batty-beta capabilities
```

Sixteen verbs and the full exit-code vocabulary. This is what an agent reads to
discover what it can do rather than guessing, and it is generated from the
command tree, so it cannot drift from what actually ships.

## 2. Session creation now returns an id (#0380)

Before this release `batty new` dispatched a URL and exited — no id, no
acknowledgement. Every script needed a fifty-line snapshot-and-poll workaround.

```sh
batty-beta new ~/Developer/brennanMKE/Batty
batty-beta new --json ~/Developer/brennanMKE/Batty
```

Expect a Session id and focused Pane id on stdout; `--json` gives
`{"sessionID":…,"paneID":…}`.

**Known gap, worth trying deliberately.** Quit Batty Beta entirely, then:

```sh
batty-beta new ~
```

A cold launch creates two Sessions — the default one at `$HOME` plus the
requested one. If the default's path resolves first, you may get *its* id back.
The guard refuses to answer when both match simultaneously, but a sequential
race remains. Recorded in #0380; the fix that would close it is teed up but
unbuilt. If you get the wrong id here, that is the known residual, not a new bug.

## 3. Agent-shaped workflow: build a layout, then put it away

This is the sequence the release is really about — an agent opening structure,
showing it to you, and cleaning up after itself.

```sh
SID=$(batty-beta new ~/Developer/brennanMKE/Batty)
echo "$SID"

# split a working pane, capture its id
PANE=$(batty-beta pane split --vertical --command "git log --oneline -20")

# idempotent find-or-create — run this twice (#0383)
GIT=$(batty-beta pane split --view git-status --unique)
GIT2=$(batty-beta pane split --view git-status --unique)
[ "$GIT" = "$GIT2" ] && echo "same pane returned — idempotent" || echo "DUPLICATE CREATED"
```

The second `--unique` call should print the same id and a stderr note that it
matched rather than created. That is the whole point: a setup script an agent
re-runs does not stack duplicate dashboards.

Then bring it to attention, tuck it away, and bring it back:

```sh
batty-beta notify --title "Build finished" --body "3 warnings"
batty-beta pane focus "$GIT"      # #0381 — focus follows, window comes forward
batty-beta pane hide "$GIT"       # #0382 — out of view, still alive
batty-beta list --json | grep -o '"isHidden":true' | wc -l   # expect 1
batty-beta pane show "$GIT"       # explicit id required — a hidden pane has no shell
```

`pane focus` should raise the window even when Batty Beta is in the background.
That was broken until this release: `makeKeyAndOrderFront` alone does not
activate an inactive app, so focus updated the model and the human saw nothing.

Reversibility:

```sh
batty-beta pane close --pane "$PANE"
batty-beta session close --session "$SID"
```

## 4. View types (#0333 — THIS IS THE ONE THAT MAY FAIL)

```sh
batty-beta pane split --view git-status --path ~/Developer/brennanMKE/Batty
batty-beta pane split --view system-metrics
batty-beta pane split --view process-status
batty-beta list panes
```

**Expected outcome is genuinely unknown.** #0333 reports that these Panes are
created correctly at the model layer — `batty list` shows the right topology
with `isHidden=false` — and never render, with the terminal Pane filling the
whole window.

Your own note on #0333 suspects that report was an artifact of #0361 ("the CLI
keeps launching a second instance"), which has since been fixed. If so, this
step now works and the issue can be closed. If the Panes still do not appear,
this step *is* the re-verification spike, and the exact commands above are the
reproduction.

Either way, record what you see. That is the highest-value observation in this
script.

Also try the menu path for comparison — View → New Pane (#0331) — since a
divergence between the CLI and menu routes would narrow the cause considerably.

## 5. Focus after close (#0337)

Needs three Panes, because with two "most recent" and "first" are the same Pane.

```sh
batty-beta new ~/Developer/brennanMKE/Batty
# split twice more in the UI, then click Pane 2 to focus it,
# then click Pane 3, then close Pane 3 with Cmd-W
```

Focus should land on **Pane 2** — the one you were last in — not Pane 1. Before
this release it always went to the leftmost.

The keyboard half is unverified: no unit test can show that typing goes to the
right Pane rather than only the focus ring moving. Type something immediately
after the close and confirm it lands where you expect.

## 6. Clipboard permission (#0390) — six checks

The re-pin silently changed the default from allow to deny, so OSC 52 reads
returned an empty reply with no prompt. This restores a real gate.

```sh
printf '\033]52;c;?\a'
```

1. **Allow** → dialog appears (it cannot name the requesting program — upstream
   does not supply that), and after approving you get a real base64 reply.
2. **Deny** → empty `52;c;` reply. That is correct, not a leak.
3. **Remember, same Session** → run it again; no second prompt.
4. **Different Session** → prompts again, independently.
5. **Relaunch** → prompts again (the decision is in-memory, never persisted).
6. **Cross-kind isolation** → allowing a *paste* prompt must NOT silently
   authorize a clipboard *read*. Review found a single shared flag doing exactly
   that; it is now per-kind.

Also worth trying: two rapid requests in a row — the first should get an
immediate deny while the dialog shows the second — and switching Sessions with a
prompt open, which should deny the outgoing one rather than leave it hanging.

## 7. Bell Feed after the ref bump (#0397)

```sh
printf '\e]9;hello\a'
```

Expect a Bell Feed entry and a macOS notification. The dependency now defers
every terminal state change by one runloop turn, and the analysis says
production is unaffected because it reads through `.onChange` — downstream of
the publish, so late but never skipped. That conclusion is from source reading
only. This one command confirms it.

## 8. SSH colours (#0392 — expected to change nothing)

```sh
echo $GHOSTTY_SHELL_FEATURES   # expect: cursor:blink,path,ssh-env,title
type ssh                       # expect: ssh is /usr/bin/ssh — NOT a function
ssh <host> 'echo $COLORTERM'   # expect: empty, same as before
```

`cursor`, `path`, and `title` being present is the proof that omitting them from
the config preserved their defaults. If `type ssh` reports a *function*, the
"inert" finding is wrong and worth saying so immediately.

This is expected to change nothing — the pinned dependency ships no `ssh()`
wrapper. #0399 owns the actual fix.

## What is not covered

- The close-confirmation dialogs (#0398). They are now unit-testable but still
  cannot fire in a running app: the polyfill returns `false`, so a Tab running
  `sleep 30` still closes silently. Nothing to demo until the upstream wrapper
  lands.
- fish, elvish, and nushell users have no shell integration at all (#0400) — no
  cwd tracking, no prompt marks, frozen tab titles. If your login shell is one of
  those, expect §3's cwd-dependent steps to behave oddly.
</content>
