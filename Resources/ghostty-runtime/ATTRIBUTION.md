# Ghostty runtime resources

These files are vendored from the [Ghostty](https://github.com/ghostty-org/ghostty)
project's bundled resources. They live at `Resources/ghostty-runtime/` so the
`scripts/bundle-ghostty-resources.sh` build phase can copy them into
`Batty.app/Contents/Resources/` with their original directory layout preserved
(Xcode's filesystem-synchronized groups otherwise flatten subfolders).

**This is not a single-license tree.** Most of it is Ghostty's own MIT code
(© Ghostty contributors), but three shell-integration files are GPLv3
(Kitty-derived) and one is a separate MIT-licensed upstream project. See
"Contents" below for exactly which files fall under which license.

**For the verbatim license text this vendoring obligates Batty to
carry — Ghostty's own MIT notice, the three GPLv3 files (whose full
license text now ships as `gpl-3.0.txt`, see "Contents" below), and
`bash-preexec`'s own MIT notice — see the "Ghostty runtime resources",
"GPLv3 files (Kitty-derived)", and "bash-preexec" sections of
[`/THIRD-PARTY-LICENSES.md`](../../THIRD-PARTY-LICENSES.md) at the repo
root (`#0318`, `#0323`). Keep that document's description of what ships
here in sync with this file if the vendored contents ever change.**

## Contents

- `terminfo/78/xterm-ghostty` — terminfo entry libghostty installs into `$TERMINFO_DIRS` so `$TERM=xterm-ghostty` resolves cleanly inside a Batty surface. Ghostty MIT.
- `ghostty/shell-integration/fish/...`, `ghostty/shell-integration/elvish/...`, `ghostty/shell-integration/nushell/...` — shell-integration scripts libghostty sources to enable cwd tracking (OSC 7), command-finished markers (OSC 133), prompt marking, etc. Ghostty MIT; no divergent header found in these three.
- **GPLv3 (Kitty-derived), not MIT:**
  - `ghostty/shell-integration/bash/ghostty.bash`
  - `ghostty/shell-integration/zsh/.zshenv`
  - `ghostty/shell-integration/zsh/ghostty-integration`

  Each carries its own header stating it's based on Kitty's shell
  integration and is therefore GPLv3 — Ghostty's blanket MIT notice does
  not cover these three files. See `THIRD-PARTY-LICENSES.md` for the
  verbatim notice.
- `ghostty/shell-integration/gpl-3.0.txt` — a verbatim, unmodified copy
  of the GNU GPLv3 license text (fetched from
  <https://www.gnu.org/licenses/gpl-3.0.txt>, 674 lines), added by
  `#0323` so the three files above ship a copy of their governing
  license alongside them, not just a link to one. It ships into the
  same bundle directory as those files via the existing
  `rsync -a --delete .../shell-integration/` step in
  `scripts/bundle-ghostty-resources.sh` — no script change needed.
- **Separate MIT project, not Ghostty's own code:**
  `ghostty/shell-integration/bash/bash-preexec.sh` vendors
  [`rcaloras/bash-preexec`](https://github.com/rcaloras/bash-preexec)
  (v0.6.0), MIT licensed, © Ryan Caloras and contributors. See
  `THIRD-PARTY-LICENSES.md` for its own notice.

## Updating

When `libghostty-spm` is bumped to a newer Ghostty version, copy these files
from a build of the matching Ghostty version (or from a developer machine that
has Ghostty installed at a compatible version):

```bash
cp -R /Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty \
      Resources/ghostty-runtime/terminfo/78/xterm-ghostty
cp -R /Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration \
      Resources/ghostty-runtime/ghostty/shell-integration
```

**After updating, re-check every file for a license header that diverges
from Ghostty's own MIT** (the GPLv3 files above are a known, standing
divergence; a future Ghostty version could add or drop others) and update
both this file and `THIRD-PARTY-LICENSES.md` together if anything changed.

**`gpl-3.0.txt` is not part of upstream Ghostty** — it's Batty's own
addition (`#0323`), not something the `cp -R` step above would ever
produce on its own (that command, run as written against an
already-existing destination directory, merges into it rather than
replacing it — it does not delete `gpl-3.0.txt`). The risk is only with
a refresh that genuinely **replaces rather than merges** the directory
(an `rm -rf` first, or an `rsync --delete` sourced from upstream
instead of from this repo) — that kind of refresh would drop
`gpl-3.0.txt` along with everything else not present upstream. After
any such refresh, re-fetch (or re-copy) `gpl-3.0.txt` from
<https://www.gnu.org/licenses/gpl-3.0.txt> into
`Resources/ghostty-runtime/ghostty/shell-integration/gpl-3.0.txt` and
confirm it's still 674 lines before committing the version bump.

## License

**Mixed — see "Contents" above.** Most files: MIT, retained from upstream,
see https://github.com/ghostty-org/ghostty/blob/main/LICENSE. Three files:
GPLv3 (Kitty-derived). One file: a separate upstream MIT project
(`bash-preexec`). Do not treat this tree as uniformly MIT.
