# Third-Party Licenses

Batty is MIT-licensed (see `LICENSE`). Batty's binary and source
distribution also includes code and data from the third-party projects
listed below. Each entry reproduces the copyright notice and permission
text exactly as published by that project, as required by its license.

This file is **hand-maintained**, not generated. It was compiled for
issue `#0318` by reading each project's `LICENSE` file directly from its
GitHub repository at the exact revision pinned in
`BattyKit/Package.resolved` (via `gh api repos/<owner>/<repo>/contents/LICENSE?ref=<revision>`),
or, for the `GhosttyKit.xcframework` binary vendored by `libghostty-spm`,
by reading the `LICENSE` of the upstream `ghostty-org/ghostty` source
repository that `libghostty-spm`'s `Script/build-ghostty.sh` clones and
compiles at build time.

**A copy of this file also ships inside the app**, rendered in-app as a
Help topic — Help menu → Batty Help → "Third-Party Licenses" — backed by
`BattyKit/Sources/BattyKit/Help/09-third-party-licenses.md`. That's the
same seam the other eight Help topics use
(`BattyKit/Sources/BattyKit/Views/Help/HelpCatalog.swift`,
`HelpView.swift`), not a new UI surface. In the built app the file lands
at `Batty.app/Contents/Resources/BattyKit_BattyKit.bundle/Contents/Resources/Help/09-third-party-licenses.md`
(confirmed by inspecting a fresh `scripts/build.sh` product — `.copy("Help")`
in `BattyKit/Package.swift` preserves the `Help/` subdirectory rather than
flattening it the way `.process("Resources")` does).

**Why not a clickable link from the About panel:** an earlier round of
this issue linked the About panel's credits text straight to a bundled
`.md` file via `NSAttributedString`'s `.link` attribute. Reviewed and
reverted: a `file://` link to a `.md` resolves through `NSWorkspace.open`,
and stock macOS has no default handler for that extension — most users
would get "no application set to open the document" instead of the
notices. Routing the link through Batty's own `batty://` URL scheme
instead was considered and rejected: `BattyURLHandler` is deliberately
scoped to one job (`batty://session?path=`), and both of the app's
scenes explicitly opt out of `handlesExternalEvents` to avoid SwiftUI
spawning a stray window on a `batty://` open (`BattyApp.swift`, `#0251`)
— teaching a new URL form to open the separate `Window("Batty Help", id:
"help")` scene from inside a system-owned `NSTextView` we don't control
is real surface area for a legal-notice link that doesn't need it. The
About panel's credits text instead names the components in plain text
and points at "Help → Third-Party Licenses" — always reachable, no
Launch Services dependency, no new event-routing path.

**Keeping the two copies in sync is enforced by a test, not just this
paragraph:** `BattyKitTests/ThirdPartyLicensesSyncTests.swift` asserts
this file's content is byte-identical to
`BattyKit/Sources/BattyKit/Help/09-third-party-licenses.md`. It runs in
`scripts/build.sh unit`, the pre-commit gate — drift fails the build,
it doesn't rely on a maintainer remembering. When updating one file,
update the other in the same commit; the test is there so a forgotten
half doesn't silently ship.

**How to keep this current when dependency pins change:** whenever
`BattyKit/Package.resolved` gets a new revision/version for any pin, or
`BattyKit/Package.swift` adds or removes a dependency, re-verify every
affected entry below against the *new* pinned commit — license text and
even the declared license can change between versions — and don't assume
a prior entry still applies. Re-fetch with
`gh api repos/<owner>/<repo>/contents/LICENSE?ref=<new-revision>` (or the
correct license filename; not every project calls it `LICENSE`) and
paste the verbatim result in. If a component ever stops shipping in the
bundle (dependency removed, target no longer links it), remove its
section rather than leaving stale text. **This inventory also covers
resources that ship without ever appearing in `Package.resolved`** —
vendored files bundled by a dependency's own build step (like Prism.js
inside `textual`) or copied in by Batty's own build phases (like
`Resources/ghostty-runtime/`) — so a pin-diff alone won't surface
everything that needs re-checking; skim the actual build product
(`find Batty.app/Contents/Resources -type f`) periodically too.

**Repo-side resource directories, swept for this round:** the repo's
`Resources/` folder at the root contains exactly one subtree,
`ghostty-runtime/` — fully swept, see that section below (3 GPLv3
files found; everything else there is Ghostty's own MIT or the
separate `bash-preexec` MIT notice). `Batty/Assets.xcassets` is
Batty's own first-party asset catalog (icons, colors), not third-party
content. There is exactly one build script that copies a repo-side
resource tree into the bundle
(`scripts/bundle-ghostty-resources.sh`, covering `ghostty-runtime/`) —
checked via `ls scripts/ | grep bundle`. No other repo-side resource
directory ships.

---

## Terminal color theme catalog (iTerm2-Color-Schemes)

**Provenance chain:** `mbadolato/iTerm2-Color-Schemes` → generated into
`Lakr233/libghostty-spm`'s `GhosttyTheme` target
(`GhosttyThemeCatalog.allThemes`, ~485 entries) → merged into Batty's
`BattyThemeCatalog.allThemes` (`BattyKit/Sources/BattyKit/Theme/BattyThemeCatalog.swift`).
See `docs/themes.md` §2 for the full mechanics.

**Ships in the bundle:** yes — the theme data compiles into the
`GhosttyTheme` module, which is part of `BattyKit`, which is what the
`Batty` and `Batty Beta` app products, and the embedded `batty` CLI
binary (`Contents/Resources/bin/batty`), link against.

**Verified against:** the `LICENSE` file inside `libghostty-spm`'s own
`Sources/GhosttyTheme/` directory (the location the theme data actually
ships from), fetched at the pinned revision
(`b146b73a8ba3ed2678a22a9de5feecfcbf298d48`) via
`gh api repos/Lakr233/libghostty-spm/contents/Sources/GhosttyTheme/LICENSE`,
cross-checked against `mbadolato/iTerm2-Color-Schemes`'s own repository
`LICENSE` (`master` branch) via
`gh api repos/mbadolato/iTerm2-Color-Schemes/contents/LICENSE`. Both
agree on the MIT text and the "Mark Badolato" copyright line.

> Note: the `libghostty-spm` copy of this notice excludes itself from
> the compiled target (`.target(name: "GhosttyTheme", ..., exclude: ["LICENSE"])`
> in `libghostty-spm`'s `Package.swift`) — it documents the obligation
> but does not itself get bundled by SwiftPM. That's the actual root
> cause of this issue: the notice exists upstream, but nothing carried
> it forward into Batty's shipped artifact until now.

```
MIT License

Color scheme data sourced from iTerm2-Color-Schemes
(https://github.com/mbadolato/iTerm2-Color-Schemes)

Copyright (c) 2011-present Mark Badolato

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Unverified caveat — read before treating this as complete:**
`iTerm2-Color-Schemes`'s own root `LICENSE` file (reproduced in full
below) ends with two lines that the notice above does not carry:

> This license covers the iTerm-Color-Schemes repository collection of
> themes.
>
> The copyright/license for each individual theme belongs to the author
> of that theme.

That means the Mark Badolato / MIT notice covers the *collection* —
compilation, tooling, repository structure — but **each of the ~485
individual theme definitions may carry its own separate authorship and
license that this document does not enumerate.** Cataloging per-theme
authorship for ~485 entries was out of scope for this pass (`#0318`
scoped this as a hand-maintained, not generated, inventory). This is
flagged here explicitly rather than silently treated as fully covered
by the collection-level MIT notice — if a specific theme's provenance
is ever challenged, check `mbadolato/iTerm2-Color-Schemes`'s per-scheme
source directory for that theme's own attribution first.

Root `LICENSE` of `mbadolato/iTerm2-Color-Schemes` (`master` branch, for
the record):

```
MIT License

Copyright (c) 2011 to Present Mark Badolato

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

This license covers the iTerm-Color-Schemes repository collection of themes.

The copyright/license for each individual theme belongs to the author of that theme.
```

---

## libghostty-spm

**Source:** `Lakr233/libghostty-spm`, pinned in `BattyKit/Package.swift`
by `revision: "b146b73a8ba3ed2678a22a9de5feecfcbf298d48"`. Supplies the
`GhosttyKit`, `GhosttyTerminal`, and `GhosttyTheme` Swift wrapper
modules Batty links against, plus the `GhosttyKit.xcframework` binary
target described in the next section.

**License:** MIT. **Copyright:** `(c) 2026 @Lakr233`.

**Ships in the bundle:** yes — compiles into `BattyKit`, linked by the
`Batty` / `Batty Beta` app products and the embedded `batty` CLI.

**Verified against:** the repository's root `LICENSE` file at the
pinned revision, `gh api repos/Lakr233/libghostty-spm/contents/LICENSE?ref=b146b73a8ba3ed2678a22a9de5feecfcbf298d48`,
cross-checked against the local clone at `~/Developer/brennanMKE/libghostty-spm/LICENSE`.

```
MIT License

Copyright (c) 2026 @Lakr233

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Ghostty (vendored as the GhosttyKit.xcframework binary)

**Source:** `ghostty-org/ghostty`. `libghostty-spm` does not vendor
Ghostty's source in its own repository — `Script/build-ghostty.sh`
clones `https://github.com/ghostty-org/ghostty` at build time
(`References/ghostty-upstream`), applies its own patch set
(`Patches/ghostty/`), and compiles the result into
`GhosttyKit.xcframework`'s static libraries
(`libghostty.a` per platform slice), which `libghostty-spm`'s
`Package.swift` declares as a `binaryTarget` and Batty links
transitively through the `GhosttyKit` product. Batty does not pin an
exact Ghostty commit itself — that pin lives inside whichever
`libghostty-spm` release built the `GhosttyKit.xcframework.zip` that
`Package.swift`'s `libghostty` binary target checksum resolves to;
this document did not trace that release-to-Ghostty-commit mapping
further (out of scope for a license inventory).

**License:** MIT. **Copyright:** `(c) 2024 Mitchell Hashimoto, Ghostty
contributors`.

**Ships in the bundle:** yes — `libghostty.a` is statically linked into
the compiled `GhosttyKit` module, which is part of `BattyKit`, present
in the `Batty` / `Batty Beta` binaries and the embedded `batty` CLI.

**Verified against:** `ghostty-org/ghostty`'s root `LICENSE` on its
default branch, `gh api repos/ghostty-org/ghostty/contents/LICENSE`
(GitHub's API also reports `license.spdx_id: "MIT"` for this repo).

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Ghostty runtime resources (a second, separate shipping path)

**This is distinct from the previous section.** The section above covers
`libghostty.a`, the *compiled* Ghostty code statically linked into
`GhosttyKit`. Separately, Batty's own repository checks in a copy of
Ghostty's runtime *files* — terminfo entry and shell-integration
scripts — at `Resources/ghostty-runtime/`, and
`scripts/bundle-ghostty-resources.sh` (a restricted build script; this
document only records what it already does, and does not modify it)
copies them into the app bundle with their original layout preserved.
Confirmed present in a fresh build product:

- `Resources/ghostty-runtime/terminfo/78/xterm-ghostty` →
  `Contents/Resources/terminfo/78/xterm-ghostty`
- `Resources/ghostty-runtime/ghostty/shell-integration/{bash,zsh,fish,elvish,nushell}/...` →
  `Contents/Resources/ghostty/shell-integration/{bash,zsh,fish,elvish,nushell}/...`

**License: mixed, not a single blanket MIT notice.** An earlier round of
this document said "MIT, same Ghostty notice as the section above" for
this entire path. That was wrong for three of the files here — see
"GPLv3 files (Kitty-derived)" immediately below. The remaining files on
this path — `terminfo/78/xterm-ghostty`, and the `bash-preexec.sh`,
`elvish`, `fish`, and `nushell` shell-integration files — carry no
divergent header and are covered by Ghostty's own MIT notice (verbatim
in the section above), **except** `bash-preexec.sh`, which is its own
separate MIT-licensed upstream project — see "bash-preexec" below.

**Sweep performed for this round:** every file under
`Resources/ghostty-runtime/` was checked for a license header
(`grep`-scanned for `kitty`/`GPL`/`copyright`/`license`, then the header
of each file read directly) — 7 shell-integration files (`bash/ghostty.bash`,
`bash/bash-preexec.sh`, `zsh/.zshenv`, `zsh/ghostty-integration`,
`fish/vendor_conf.d/ghostty-shell-integration.fish`,
`elvish/lib/ghostty-integration.elv`,
`nushell/vendor/autoload/ghostty.nu`) plus the one `terminfo` entry.
(This sweep predates `#0323`'s `gpl-3.0.txt`, now an 8th file in
`shell-integration/` — it's Batty's own addition, the license text
itself rather than a file that needs a license-header check, so it's
not counted in this sweep's 7.)
Result: **3 files carry a GPLv3 header** (below), **1 file carries a
separate MIT header** (`bash-preexec.sh`, its own section below), and
the remaining 4 (`fish`, `elvish`, `nushell`, `terminfo`) have no
license header of their own and fall under Ghostty's blanket MIT
notice. The one `kitty` string match in the `elvish` file
(`ghostty-integration.elv:188`) is an OSC 7 URL scheme
(`"\e]7;kitty-shell-cwd://..."`), not a license reference.

### GPLv3 files (Kitty-derived)

**Three files are GPLv3, not MIT**, per their own explicit headers —
confirmed both in the locally vendored copies and independently
re-fetched from `ghostty-org/ghostty`'s own repository (byte-identical
to the local copies, so this is Ghostty's own header, not something
that drifted locally):

- `Resources/ghostty-runtime/ghostty/shell-integration/bash/ghostty.bash`
  → `Contents/Resources/ghostty/shell-integration/bash/ghostty.bash`
- `Resources/ghostty-runtime/ghostty/shell-integration/zsh/.zshenv`
  → `Contents/Resources/ghostty/shell-integration/zsh/.zshenv`
- `Resources/ghostty-runtime/ghostty/shell-integration/zsh/ghostty-integration`
  → `Contents/Resources/ghostty/shell-integration/zsh/ghostty-integration`

Each file's own header states it derives from **Kitty**'s shell
integration (`kovidgoyal/kitty`), and that Kitty is GPLv3, so the
derived file is too. Kitty's own source files (e.g. `kitty/main.py`)
carry `# License: GPL v3 Copyright: 2016, Kovid Goyal <kovid at
kovidgoyal.net>` — the shell-integration file Ghostty forked from
doesn't repeat a copyright line itself, so **copyright holder: Kovid
Goyal**, inferred from Kitty's project-wide header convention rather
than stated verbatim in the specific forked file.

**Verified against:** `gh api repos/ghostty-org/ghostty/contents/src/shell-integration/bash/ghostty.bash`,
`.../zsh/.zshenv`, and `.../zsh/ghostty-integration` (all three
byte-identical to the vendored copies in `Resources/ghostty-runtime/`),
plus `gh api repos/kovidgoyal/kitty/contents/kitty/main.py` for the
copyright-holder inference above.

**What's reproduced here is the notice as it actually ships** — the
short, standard GPLv3 boilerplate notice each file carries in its own
header, verbatim:

```
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
```

**Full GPLv3 text:** not reproduced inline in this document — at 674
lines it would roughly double the length of this document for a
license that already tells the reader exactly where to find it — but
**a verbatim copy now ships in the app bundle** alongside the files it
governs (`#0323`), at
`Contents/Resources/ghostty/shell-integration/gpl-3.0.txt` **in the
built app**. Its repo-side source is
`Resources/ghostty-runtime/ghostty/shell-integration/gpl-3.0.txt`,
fetched unmodified from the canonical URL the notice above itself
points to, <https://www.gnu.org/licenses/gpl-3.0.txt> (confirmed
674 lines, byte-for-byte, both at fetch time and again while preparing
this entry) — it ships with no build-script change because it sits
inside the directory `scripts/bundle-ghostty-resources.sh` already
rsyncs wholesale (`rsync -a --delete .../shell-integration/
.../shell-integration/`).

**Why this satisfies GPLv3 §4 (verbatim copying):** these three files
ship in Batty's bundle in their original, unmodified **source form** —
plain shell scripts, not compiled or bundled into a binary the way
`libghostty.a`, Prism.js, or the math fonts are — so §4 is the
operative clause here, not §§5–6 (modified versions / conveying in
object form). §4's text is four semicolon-separated clauses, grouped
here into three requirements since the middle two are both a "keep
intact" instruction: conspicuously and appropriately publishing "on
each copy an appropriate copyright notice"; keeping "intact all
notices" stating that the License (and any non-permissive added terms)
applies, and, separately, keeping intact all notices of the absence of
any warranty; and giving "all recipients a copy of this License along
with the Program." The first two grouped requirements are satisfied by
the files' own unedited headers — Batty's build doesn't touch them
beyond copying the tree (`scripts/bundle-ghostty-resources.sh`, not
modified by this issue). **The third was the actual gap** — an earlier
version of this document linked the license text at the URL above but
did not ship a copy of it, and a URL is arguably not "a copy along with
the Program." `#0323` closed that gap by vendoring `gpl-3.0.txt`
itself, above, so all of §4's requirements are now met by what ships,
not just by this document's notice of them.

There is an existing `Resources/ghostty-runtime/ATTRIBUTION.md` in the
repository documenting this vendoring, updated alongside this issue to
name both the GPLv3 files above and `bash-preexec` (next section) and
to point at this file for the verbatim/linked notice text, so the two
don't drift apart silently.

---

## bash-preexec (vendored inside Ghostty's bash shell-integration)

**Source:** `rcaloras/bash-preexec`, v0.6.0 per the file's own header
comment (`# V0.6.0`). Ghostty vendors this file as part of its bash
shell integration; Ghostty's own MIT notice does not cover it, and
neither does the GPLv3 notice on `ghostty.bash` in the same directory —
it is a separate upstream project with its own copyright holder and
its own (third) license on this one shipping path.

**Ships in the bundle:** yes, as part of the Ghostty runtime resources
path above:
`Resources/ghostty-runtime/ghostty/shell-integration/bash/bash-preexec.sh`
→ `Contents/Resources/ghostty/shell-integration/bash/bash-preexec.sh`.
The shipped copy carries **no copyright or license text at all** — only
a `# Author: Ryan Caloras (ryan@bashhub.com)` comment in its header.
That gap is exactly why this entry exists.

**License:** MIT. **Copyright:** `(c) 2017 Ryan Caloras and
contributors`.

**Verified against:** the `rcaloras/bash-preexec` repository's
`LICENSE.md` at the `0.6.0` tag,
`gh api repos/rcaloras/bash-preexec/contents/LICENSE.md?ref=0.6.0`.

```
The MIT License

Copyright (c) 2017 Ryan Caloras and contributors (see https://github.com/rcaloras/bash-preexec)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## MSDisplayLink

**Source:** `Lakr233/MSDisplayLink`, resolved transitively (not a
direct `BattyKit/Package.swift` dependency — it's `GhosttyTerminal`'s
own dependency inside `libghostty-spm`'s `Package.swift`) at
`revision: "1ba3e769b734e456317fa7e45321fa7f53eefb67"` (version
`2.1.0`) per `BattyKit/Package.resolved`.

**License:** MIT. **Copyright:** `(c) 2024 Lakr Aream`.

**Ships in the bundle:** yes — linked by `GhosttyTerminal`, part of
`BattyKit`.

**Verified against:** the repository's `LICENSE` file at the pinned
revision, `gh api repos/Lakr233/MSDisplayLink/contents/LICENSE?ref=1ba3e769b734e456317fa7e45321fa7f53eefb67`.

```
MIT License

Copyright (c) 2024 Lakr Aream

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Sparkle

**Source:** `sparkle-project/Sparkle`, pinned in
`BattyKit/Package.swift` (`from: "2.6.0"`); `BattyKit/Package.resolved`
currently resolves it to `revision: "066e75a8b3e99962685d6a90cdd5293ebffd9261"`
(version `2.9.1`). Drives Batty's auto-update flow
(`BattyKit/Sources/BattyKit/Updater/UpdaterController.swift`).

**License:** MIT-style, plus several bundled third-party notices for
code Sparkle itself vendors (see full text below). **Copyright:**
multiple holders — Andy Matuschak, Elgato Systems GmbH, Kornel
Lesiński, Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd
Ranch (primary notice), plus Colin Percival (bsdiff/bsplit), Yuta Mori
(sais-lite), Orson Peters (ed25519), and Mark Hamlin
(`SUSignatureVerifier.m`) for vendored components.

**Ships in the bundle:** confirmed by inspecting a fresh `scripts/build.sh`
output (`#0318`) — `Sparkle.framework` is embedded at
`Contents/Frameworks/Sparkle.framework`, including its `Autoupdate`
binary, `Updater.app`, and `XPCServices/Downloader.xpc` +
`XPCServices/Installer.xpc`. This is Sparkle's standard SwiftPM/Xcode
integration; there is no manual embed step in
`Batty.xcodeproj/project.pbxproj` — Xcode adds it automatically because
`BattyKit` (linked by the app target) depends on the `Sparkle` product.

**Verified against:** the repository's `LICENSE` file at the pinned
revision, `gh api repos/sparkle-project/Sparkle/contents/LICENSE?ref=066e75a8b3e99962685d6a90cdd5293ebffd9261`.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

---

## textual

**Source:** `gonzalezreal/textual`, pinned in `BattyKit/Package.swift`
by `revision: "5b06b811c0f5313b6b84bbef98c635a630638c38"`. Used for
Markdown rendering.

**License:** MIT. **Copyright:** `(c) 2024 Guille Gonzalez`.

**Ships in the bundle:** yes — the `Textual` product is a direct
`BattyKit` target dependency.

**Verified against:** the repository's `LICENSE` file at the pinned
revision, `gh api repos/gonzalezreal/textual/contents/LICENSE?ref=5b06b811c0f5313b6b84bbef98c635a630638c38`.

```
MIT License

Copyright (c) 2024 Guille Gonzalez

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Prism.js (vendored inside textual, not a `Package.resolved` pin)

**Source:** `PrismJS/prism`, vendored by `gonzalezreal/textual` — not as
a Swift package dependency, but as a build artifact.  `textual`'s
`Package.swift` declares `resources: [.process("Internal/Highlighter/Prism")]`
on the `Textual` target, and its own `Scripts/bundle-prism.sh` (run at
`textual`'s release time, not Batty's build time) produces a single
bundled `prism-bundle.js`. Because this ships as a *resource*, not a
resolved package dependency, it does not appear anywhere in
`BattyKit/Package.resolved` — a pin diff alone will never surface it.

**Ships in the bundle:** confirmed present in a fresh build product at
`Contents/Resources/textual_Textual.bundle/Contents/Resources/prism-bundle.js`
(128 KB). Used for syntax highlighting of code blocks in Markdown
rendered by `Textual` — including, incidentally, the Help topic this
very document ships as.

**Version:** v1.29.0, per the bundled file's own header comment
(`// Prism.js v1.29.0 - Bundled on Tue Dec 16 16:41:27 CET 2025 // Auto-generated
by Scripts/bundle-prism.sh - DO NOT EDIT`). That bundling script strips
Prism's copyright header in the process — **the shipped
`prism-bundle.js` carries no copyright line at all.** This is precisely
the defect class `#0318` exists to fix: a real upstream project's code
ships with its own notice silently dropped along the way.

**License:** MIT. **Copyright:** `(c) 2012 Lea Verou`.

**Verified against:** the `PrismJS/prism` repository's `LICENSE` file at
the `v1.29.0` tag, `gh api repos/PrismJS/prism/contents/LICENSE?ref=v1.29.0`.

```
MIT LICENSE

Copyright (c) 2012 Lea Verou

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## swiftui-math

**Source:** `gonzalezreal/swiftui-math`, resolved transitively (a
dependency of `textual`, not a direct `BattyKit/Package.swift` entry)
at `revision: "0b5c2cfaaec8d6193db206f675048eeb5ce95f71"` (version
`0.1.0`) per `BattyKit/Package.resolved`. Provides LaTeX-style math
rendering that `Textual` links (`SwiftUIMath` product).

**This entry covers the package's own code only.** The package also
bundles 12 third-party OTF math fonts under `mathFonts.bundle` with
their own, separate licenses — see "Bundled fonts" below. Saying
"License: MIT" for the whole package would be wrong; the code is MIT,
the fonts mostly are not.

**License (code):** MIT. **Copyright:** `(c) 2026 Guille Gonzalez`,
`(c) 2023 Computer Inspirations (SwiftMath)`,
`(c) 2013 MathChat (iosMath)` — three stacked notices, reflecting that
this package is itself derived from earlier `SwiftMath` / `iosMath`
work.

**Ships in the bundle:** yes — linked by `Textual`, part of `BattyKit`.

**Verified against:** the repository's `LICENSE` file at the pinned
revision, `gh api repos/gonzalezreal/swiftui-math/contents/LICENSE?ref=0b5c2cfaaec8d6193db206f675048eeb5ce95f71`.

```
MIT License

Copyright (c) 2026 Guille Gonzalez
Copyright (c) 2023 Computer Inspirations (SwiftMath)
Copyright (c) 2013 MathChat (iosMath)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Bundled fonts

`Sources/SwiftUIMath/mathFonts.bundle` in `swiftui-math` ships 12 OTF
math font files, confirmed present in the built app at
`Contents/Resources/swiftui-math_SwiftUIMath.bundle/Contents/Resources/mathFonts.bundle/`:
`Asana-Math.otf`, `Euler-Math.otf`, `FiraMath-Regular.otf`,
`Garamond-Math.otf`, `KpMath-Light.otf`, `KpMath-Sans.otf`,
`latinmodern-math.otf`, `LeteSansMath.otf`, `LibertinusMath-Regular.otf`,
`NotoSansMath-Regular.otf`, `texgyretermes-math.otf`, `xits-math.otf`.

Alongside the fonts, the bundle carries exactly three license files —
also present in the built app at the same path — which travel with the
fonts wherever `mathFonts.bundle` goes, satisfying the mechanical
"included in all copies" obligation for whichever fonts they cover:

- **`LICENSE`** — the MIT/MathChat notice already reproduced above (the
  package's own code license; identical text, not repeated here).
- **`OFL.txt`** — titled "STIX Font License" but its body is the **SIL
  Open Font License, Version 1.1**, with a STIX-specific copyright
  preamble. Reproduced verbatim below.
- **`GUST-FONT-LICENSE.txt`** — the **GUST Font License**, i.e. the
  **LaTeX Project Public License, version 1.3c or later**, plus one
  extra GUST-specific clause. Reproduced verbatim below.

**Mapping fonts to licenses — partially established, not exhaustive.**
By filename, `xits-math.otf` is XITS Math (the STIX-derived font `OFL.txt`
names) and `latinmodern-math.otf` is Latin Modern Math (GUST's own font,
matching `GUST-FONT-LICENSE.txt`'s GUST/LPPL terms) — those two fonts'
licenses are established with reasonable confidence from the file names
alone. **The other 10 fonts** (`Asana-Math`, `Euler-Math`, `FiraMath-Regular`,
`Garamond-Math`, `KpMath-Light`, `KpMath-Sans`, `LeteSansMath`,
`LibertinusMath-Regular`, `NotoSansMath-Regular`, `texgyretermes-math`)
are each their own upstream font project and **this pass did not trace
each one to its own license** — `swiftui-math`'s own repository ships
only these three license files for all 12 fonts, with no per-font
manifest mapping name → license → holder. Marking this explicitly
unverified rather than assuming all 10 fall under one of the three
texts above, which would be a guess, not a verification. Both blocking
findings in this review round (Prism.js, iTerm2-Color-Schemes's
per-theme caveat above) were exactly this failure mode caught in time;
this is the same caveat applied consistently rather than glossed over
a third time.

**Verified against:** the built app's own copies of `OFL.txt` and
`GUST-FONT-LICENSE.txt` inside `mathFonts.bundle` (the primary source
for what actually ships — cross-checked against
`gh api repos/gonzalezreal/swiftui-math/contents/Sources/SwiftUIMath/mathFonts.bundle/OFL.txt?ref=0b5c2cfaaec8d6193db206f675048eeb5ce95f71`
and the equivalent path for `GUST-FONT-LICENSE.txt`, both matching).

```
STIX Font License

24 May 2010

Copyright (c) 2001-2010 by the STI Pub Companies, consisting of the American
Institute of Physics, the American Chemical Society, the American Mathematical
Society, the American Physical Society, Elsevier, Inc., and The Institute of
Electrical and Electronic Engineers, Inc. (www.stixfonts.org), with Reserved
Font Name STIX Fonts, STIX Fonts (TM) is a  trademark of The Institute of
Electrical and Electronics Engineers, Inc.

Portions copyright (c) 1998-2003 by MicroPress, Inc. (www.micropress-inc.com),
with Reserved Font Name TM Math. To obtain additional mathematical fonts, please
contact MicroPress, Inc., 68-30 Harrow Street, Forest Hills, NY 11375, USA,
Phone: (718) 575-1816.

Portions copyright (c) 1990 by Elsevier, Inc.

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL

---------------------------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
---------------------------------------------------------------------------

PREAMBLE

The goals of the Open Font License (OFL) are to stimulate worldwide development
of collaborative font projects, to support the font creation efforts of academic
and linguistic communities, and to provide a free and open framework in which
fonts may be shared and improved in partnership with others.

The OFL allows the licensed fonts to be used, studied, modified and redistributed
freely as long as they are not sold by themselves. The fonts, including any
derivative works, can be bundled, embedded, redistributed and/or sold with any
software provided that any reserved names are not used by derivative works. The
fonts and derivatives, however, cannot be released under any other type of license.
The requirement for fonts to remain under this license does not apply to any
document created using the fonts or their derivatives.

DEFINITIONS

"Font Software" refers to the set of files released by the Copyright Holder(s) under
this license and clearly marked as such. This may include source files, build
scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the copyright
statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting, or
substituting -- in part or in whole -- any of the components of the Original Version,
by changing formats or by porting the Font Software to a new environment.

"Author" refers to any designer, engineer, programmer, technical writer or other
person who contributed to the Font Software.

PERMISSION & CONDITIONS

Permission is hereby granted, free of charge, to any person obtaining a copy of the
Font Software, to use, study, copy, merge, embed, modify, redistribute, and sell
modified and unmodified copies of the Font Software, subject to the following
conditions:

1) Neither the Font Software nor any of its individual components, in Original or
Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled, redistributed
and/or sold with any software, provided that each copy contains the above copyright
notice and this license. These can be included either as stand-alone text files,
human-readable headers or in the appropriate machine-readable metadata fields within
text or binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font Name(s) unless
explicit written permission is granted by the corresponding Copyright Holder. This
restriction only applies to the primary font name as presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font Software shall
not be used to promote, endorse or advertise any Modified Version, except to
acknowledge the contribution(s) of the Copyright Holder(s) and the Author(s) or with
their explicit written permission.

5) The Font Software, modified or unmodified, in part or in whole, must be distributed
entirely under this license, and must not be distributed under any other license. The
requirement for fonts to remain under this license does not apply to any document
created using the Font Software.

TERMINATION

This license becomes null and void if any of the above conditions are not met.

DISCLAIMER

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER
RIGHT. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF THE USE OR
INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.
```

```
% This is a preliminary version (2006-09-30), barring acceptance from
% the LaTeX Project Team and other feedback, of the GUST Font License.
% (GUST is the Polish TeX Users Group, http://www.gust.org.pl)
%
% For the most recent version of this license see
% http://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt
% or
% http://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt
%
% This work may be distributed and/or modified under the conditions
% of the LaTeX Project Public License, either version 1.3c of this
% license or (at your option) any later version.
% 
% Please also observe the following clause:
% 1) it is requested, but not legally required, that derived works be
%    distributed only after changing the names of the fonts comprising this
%    work and given in an accompanying "manifest", and that the
%    files comprising the Work, as listed in the manifest, also be given
%    new names. Any exceptions to this request are also given in the
%    manifest.
%    
%    We recommend the manifest be given in a separate file named
%    MANIFEST-<fontid>.txt, where <fontid> is some unique identification
%    of the font family. If a separate "readme" file accompanies the Work, 
%    we recommend a name of the form README-<fontid>.txt.
%
% The latest version of the LaTeX Project Public License is in
% http://www.latex-project.org/lppl.txt and version 1.3c or later
% is part of all distributions of LaTeX version 2006/05/20 or later.
```

---

## swift-concurrency-extras

**Source:** `pointfreeco/swift-concurrency-extras`, resolved
transitively (a dependency of `textual`, not a direct
`BattyKit/Package.swift` entry) at
`revision: "5a3825302b1a0d744183200915a47b508c828e6f"` (version
`1.3.2`) per `BattyKit/Package.resolved`. Provides the `ConcurrencyExtras`
product that `Textual` links.

**License:** MIT. **Copyright:** `(c) 2023 Point-Free`.

**Ships in the bundle:** yes — linked by `Textual`, part of `BattyKit`.

**Verified against:** the repository's `LICENSE` file at the pinned
revision, `gh api repos/pointfreeco/swift-concurrency-extras/contents/LICENSE?ref=5a3825302b1a0d744183200915a47b508c828e6f`.

```
MIT License

Copyright (c) 2023 Point-Free

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Note:** `textual`'s `Package.swift` also declares
`pointfreeco/swift-snapshot-testing` as a dependency, but only for its
`TextualTests` test target — it is not a dependency of the `Textual`
library product Batty links, does not appear in `BattyKit/Package.resolved`
(it was never resolved into Batty's build graph), and does not ship.
No entry needed.

---

## swift-argument-parser

**Source:** `apple/swift-argument-parser`, pinned in
`BattyKit/Package.swift` (`from: "1.5.0"`); `BattyKit/Package.resolved`
currently resolves it to `revision: "6a52f3251125d74daf04fcbd5e6f08a75d074382"`
(version `1.8.2`). Used only by the `batty` executable target (not
`BattyKit` itself, not `BattyBroker`).

**License:** Apache License 2.0, **with the Swift.org "Runtime Library
Exception."** `LICENSE.txt` in this repository is the stock Apache 2.0
boilerplate — it does not fill in an actual "Copyright [yyyy] [name of
copyright owner]" line (the placeholder text is left as-is; the
repository is owned/published by Apple under the `apple` GitHub
organization). No separate `NOTICE` file exists in the repository
(checked the repo file listing at the pinned revision).

**Ships in the bundle:** yes — statically linked into the `batty` CLI
binary, which the app's "Embed CLI" build phase places at
`Contents/Resources/bin/batty` inside the app bundle
(`Batty.xcodeproj/project.pbxproj`).

**Verified against:** the repository's `LICENSE.txt` file at the pinned
revision, `gh api repos/apple/swift-argument-parser/contents/LICENSE.txt?ref=6a52f3251125d74daf04fcbd5e6f08a75d074382`.

**Why this entry carries no obligation to act on, despite shipping:**
the file's final section is a Swift.org-standard exception clause that
directly covers Batty's exact situation (compiling `ArgumentParser`
into a binary product):

```
## Runtime Library Exception to the Apache 2.0 License: ##

    As an exception, if you use this Software to compile your source code and
    portions of this Software are embedded into the binary product as a result,
    you may redistribute such product without providing attribution as would
    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

Full `LICENSE.txt` (standard Apache License 2.0 terms, then the
exception above), reproduced verbatim:

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

    2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

    3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

    4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

    5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

    6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

    7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

    8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

    9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

    END OF TERMS AND CONDITIONS

    APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

    Copyright [yyyy] [name of copyright owner]

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

## Runtime Library Exception to the Apache 2.0 License: ##

    As an exception, if you use this Software to compile your source code and
    portions of this Software are embedded into the binary product as a result,
    you may redistribute such product without providing attribution as would
    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

---

## SlidingTabs — first-party, no obligation

**Source:** `brennanMKE/SlidingTabs`, a local path dependency
(`.package(path: "../../SlidingTabs")` in `BattyKit/Package.swift`),
not a remote pin.

**License:** MIT. **Copyright:** `(c) 2026 Brennan Stehling`.

**Verified ownership:** `git remote -v` on the local checkout at
`~/Developer/brennanMKE/SlidingTabs` resolves to
`git@github.com:brennanMKE/SlidingTabs.git` — the same GitHub
organization/owner as this repository, and the same name (`Brennan
Stehling`) as the copyright holder in both this repo's own `LICENSE`
and `SlidingTabs`' `LICENSE`. **This is first-party code — the same
author owns both projects.**

**Conclusion:** there is no third-party attribution obligation for
`SlidingTabs`. It's listed here for completeness and transparency
(the app's About panel already names it), not because MIT compliance
requires it — a copyright holder cannot infringe their own notice
requirement against themselves, and no other license terms apply.
