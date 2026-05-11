# Ghostty runtime resources

These files are vendored from the [Ghostty](https://github.com/ghostty-org/ghostty)
project's bundled resources (MIT License, © Ghostty contributors). They live at
`Resources/ghostty-runtime/` so the `scripts/bundle-ghostty-resources.sh` build
phase can copy them into `Batty.app/Contents/Resources/` with their original
directory layout preserved (Xcode's filesystem-synchronized groups otherwise
flatten subfolders).

## Contents

- `terminfo/78/xterm-ghostty` — terminfo entry libghostty installs into `$TERMINFO_DIRS` so `$TERM=xterm-ghostty` resolves cleanly inside a Batty surface.
- `ghostty/shell-integration/{bash,zsh,fish,elvish,nushell}/...` — shell-integration scripts libghostty sources to enable cwd tracking (OSC 7), command-finished markers (OSC 133), prompt marking, etc.

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

## License

MIT, retained from upstream. See https://github.com/ghostty-org/ghostty/blob/main/LICENSE
