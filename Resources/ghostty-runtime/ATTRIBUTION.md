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

**For the verbatim/linked license text this vendoring obligates Batty to
carry — Ghostty's own MIT notice, the three GPLv3 files, and
`bash-preexec`'s own MIT notice — see the "Ghostty runtime resources",
"GPLv3 files (Kitty-derived)", and "bash-preexec" sections of
[`/THIRD-PARTY-LICENSES.md`](../../THIRD-PARTY-LICENSES.md) at the repo
root (`#0318`). Keep that document's description of what ships here in
sync with this file if the vendored contents ever change.**

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
  verbatim notice and a link to the full GPLv3 text.
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

## License

**Mixed — see "Contents" above.** Most files: MIT, retained from upstream,
see https://github.com/ghostty-org/ghostty/blob/main/LICENSE. Three files:
GPLv3 (Kitty-derived). One file: a separate upstream MIT project
(`bash-preexec`). Do not treat this tree as uniformly MIT.
