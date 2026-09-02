# Ghostty colours over SSH

How terminal colour information does and does not travel to a remote host, why
neovim on `yoyo` looked washed out, and what to turn on.

*Written 2026-09-02. Ghostty 1.3.1 on cameron/the MacBook Air; targets are the
Debian 13 Pis.*

---

## The thing worth knowing first

**`COLORTERM` does not carry your theme.** It is a single word — `truecolor` or
`24bit` — and it answers exactly one question: *may I send 24-bit colour?* It
says nothing about which colours, and there is no environment variable that
does.

Your theme reaches remote programs by a different route entirely, and the two
pull in opposite directions:

| What you want | How it travels | What it needs |
|---|---|---|
| "This terminal can do 16 million colours" | `COLORTERM` env var | `SendEnv` here, `AcceptEnv` there |
| "This terminal can do italics/graphics/…" | `TERM` + a terminfo entry | the entry installed on the remote host |
| **"Use *my* colours"** | **ANSI indices 0–15, resolved by the terminal** | the remote app must emit indices, not RGB |
| "What colour is the background?" | OSC 10/11 query, answered live | app support (neovim has it) |

The fourth row is the only way an app can *ask* what your colours are. The third
is the way it can *use* them without asking — and it is the one that matters.

---

## Why neovim looked washed out

Two separate causes, which is why fixing one did not help.

**1. `COLORTERM` never arrived.** `sshd` on the Pis already accepts it:

```
AcceptEnv LANG LC_* COLORTERM NO_COLOR
```

but the Mac was never *sending* it — `~/.ssh/config` had no `SendEnv` line
anywhere. Neovim 0.10 uses `COLORTERM` to decide whether to enable
`termguicolors`; unset, it approximates its colourscheme in 256 colours, which
is the pale look.

**2. The colourscheme was itself muted.** `habamax` sets `Normal` to `#bcbcbc`
and `String` to `#87af87` — desaturated by design. Truecolor made it *accurate*,
not vivid.

### The fix that was applied

`~/.ssh/config` on the Mac, at the end of the file:

```sshconfig
Host *
    SendEnv COLORTERM NO_COLOR
```

Last in the file on purpose: `SendEnv` accumulates across matching blocks rather
than being overridden by the first match, so a per-host block still works.
A host that does not list the variable in `AcceptEnv` simply ignores it.

Verify:

```bash
ssh -G yoyo | grep -i sendenv        # local: is it configured?
ssh yoyo 'echo $COLORTERM'           # remote: did it arrive?  -> truecolor
```

---

## Better: let Ghostty do it

Ghostty 1.1+ ships SSH integration that handles both `TERM` and the environment
automatically. **Both halves are off by default.** The shipped default is:

```
shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path
```

Note `no-ssh-env` and `no-ssh-terminfo`. To enable, in
`~/Library/Application Support/com.mitchellh.ghostty/config`:

```
shell-integration-features = cursor,no-sudo,title,ssh-env,ssh-terminfo,path
```

| Feature | What it does |
|---|---|
| `ssh-terminfo` | Installs Ghostty's terminfo on the remote host automatically on first connect, so `TERM=xterm-ghostty` resolves there. Successful installs are cached — `ghostty +ssh-cache` lists them, `--clear` resets. |
| `ssh-env` | Propagates terminal environment (including `COLORTERM`) and falls back to a widely-known `TERM` on hosts where the entry cannot be installed. |

`ssh-terminfo` replaces the manual step in `yoyo/provision.sh`:

```bash
infocmp -x xterm-ghostty | ssh yoyo sudo tic -x -o /usr/share/terminfo -
```

Keep that step anyway. It covers hosts reached from something other than
Ghostty, and a reimaged Pi should not depend on which terminal happens to
connect first.

> Not yet exercised on this fleet — the `ssh-cache` is empty. When enabling it,
> check `ghostty +ssh-cache` after the first connection to confirm the host was
> recorded.

---

## Actually using the theme's colours

This is the part `COLORTERM` cannot do, and it works by giving up truecolor
rather than gaining it.

When an app emits **ANSI colour indices 0–15**, the terminal resolves each one
through its own palette at render time. That palette *is* your theme. Change the
theme and every running app changes with it, instantly, with nothing to sync.

When an app emits **24-bit RGB**, the terminal draws exactly those values. The
app's own palette wins and the theme is ignored.

So "use my terminal's theme in nvim" means: **turn `termguicolors` off.**

```lua
vim.o.termguicolors = false   -- send indices 0-15, let Ghostty resolve them
vim.cmd.colorscheme("vim")    -- a scheme that mostly stays inside 0-15
```

`vim` is the right base. Measured across 30 common highlight groups:

| Scheme | coloured from theme (0–15) | outside the palette | uncoloured |
|---|---|---|---|
| `vim` | 21 | 6 | 3 |
| `default` | 9 | 0 | 21 |
| `habamax`, `retrobox`, `quiet`, `industry` | 0 | all | — |

The six stragglers in `vim` reach into the fixed xterm cube, where they render
identically no matter how the terminal is themed — the exact thing being avoided
— so they are pulled back in:

```lua
PreProc, Include     81  (fixed light blue)  -> 14  bright cyan
Type, StorageClass   121 (fixed light green) -> 10  bright green
Special, Delimiter   224 (fixed light pink)  -> 13  bright magenta
```

Result: 26 groups coloured, none outside the palette. The live config is
[`../yoyo/files/nvim-init.lua`](../yoyo/files/nvim-init.lua).

### The trade-off, stated plainly

16 colours, not 16 million. A truecolor scheme has more range for subtle
distinctions. What you get instead is a remote editor that matches the terminal
it is running in, and keeps matching when the theme changes.

To go the other way, set `termguicolors = true` and pick a scheme — `retrobox`
or `sorbet` for vivid, `habamax` for muted. `COLORTERM` now arrives, so it will
work properly.

---

## What Ghostty knows about its own colours

```bash
ghostty +show-config              # what is actually set
ghostty +show-config --default    # the shipped defaults, for comparison
ghostty +list-themes              # bundled themes
ghostty +list-colors              # named colours Ghostty understands
```

The current config sets `background = #000000` with no `theme`, so the palette
is Ghostty's default. Setting `theme = <name>` changes indices 0–15, and with
the setup above, remote neovim follows it.

---

## Checking it end to end

```bash
ssh yoyo 'echo "TERM=$TERM COLORTERM=${COLORTERM:-unset}"'
ssh yoyo 'infocmp xterm-ghostty >/dev/null && echo terminfo-ok'
ssh yoyo 'nvim --headless -c "lua print(vim.o.termguicolors)" -c q'
```

Expected from Ghostty: `TERM=xterm-ghostty`, `COLORTERM=truecolor`,
`terminfo-ok`, and `false` — the last one deliberately, because that is what
makes nvim use your palette.

## Applying this to other hosts

`SendEnv` is already global (`Host *`), so `COLORTERM` reaches every host that
accepts it. What is per-host:

- **terminfo** — `buzz` does not have `xterm-ghostty` yet. Either enable
  `ssh-terminfo` in Ghostty, or run the `infocmp | tic` one-liner above against
  it.
- **The neovim config** — currently deployed only to `yoyo` by its
  `provision.sh`.
