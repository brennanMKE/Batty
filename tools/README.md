# tools/

Developer-only utilities. Not part of the app bundle, not built by Xcode.
Unlike `scripts/` (release pipeline, restricted per `CLAUDE.md`), this
directory holds ad-hoc developer tooling that doesn't need release-process
review.

## memsample.sh

A phys_footprint / graphics-region sampling harness for Batty (#0291, child
of the #0285 memory umbrella). It packages the proven, hand-run commands
from `issues/0285/investigation-live.md` so a before/after measurement is
one or two commands instead of copy-pasted one-liners.

No dependencies beyond stock macOS tools (`footprint`, `vmmap`, `ps`, `awk`,
`bash`). No `jq`, no Python required to run it (the script hand-builds its
own JSON; `python3 -c "import json; ..."` is only used above to *verify*
the output during harness development, not by the script itself). Runs
under macOS system bash 3.2 (`/bin/bash`), not just a Homebrew bash.

**Never reads `ps -o rss`.** The #0285 umbrella exists because RSS
under-reported real memory use by 29x and 7x on two different Batty
instances — it excludes compressed and swapped pages. Everything here reads
`phys_footprint` via `footprint -p -f bytes`. `-f bytes` (rather than the
default human-readable, 3-4-significant-figure table) is deliberate: the
rounded table can make an ~800 KB real change invisible and a rounding
artifact look like a ~1 MB phantom change. Every `*_bytes` field in the
sample output is byte-exact.

**"Threads" is a proxy, not a native thread count.** It's the count of
named `Stack ... thread N` detail lines vmmap reports, which
`issues/0285/investigation-live.md` (H4) established is 1:1 with live
threads on a healthy process. `stack_regions` is a different, larger number
(Stack + STACK GUARD + a few reserved/guard regions together, roughly 2x
the thread count) — read directly from footprint's own `stack` category
table rather than re-derived from vmmap, to avoid a region-counting bug a
naive regex is prone to (vmmap's trailing per-category summary table has
its own `Stack`/`STACK GUARD`/`Stack Guard` rows that a plain anchored grep
will also match).

**Every sample is schema-stamped, and `diff` refuses to cross schemas.**
`SCHEMA_VERSION` in the script bumps whenever a field is renamed, rescaled,
or removed (it went 1→2 when round 1 switched `*_kb` fields to `*_bytes`).
A `.kv`/`.json` sample records its `schema`; a sample from before that field
existed (round 1's KB-based output) has none at all. `diff` treats both
"missing `schema` key" and "different `schema` number" as a hard error, not
a warning — every field lookup `diff` performs dies loudly on a missing key
rather than defaulting to `0`. This exists because an earlier round diffed
a stale KB-schema sample against a fresh byte-schema sample of the *same
idle process* and printed a phantom **+1.4 GB** footprint delta at exit
code 0 — silently-defaulted deltas are exactly the false-signal class this
harness exists to prevent, so a schema mismatch (or any future field
rename) must fail loudly instead of quietly producing a wrong number.

### Resolving which process you're measuring

`pgrep Batty` is unreliable on some machines (returns nothing even with
Batty running) — this harness matches the full binary path instead, and
distinguishes release from beta explicitly:

- release: `/Applications/Batty.app/Contents/MacOS/Batty` (bundle id `co.sstools.Batty`)
- beta: `.../Batty Beta.app/Contents/MacOS/Batty Beta` (bundle id `co.sstools.Batty.beta`, from `Configuration/Beta.xcconfig`)

Every sample and invariant check prints its resolved target and full binary
path so mixing up release and beta samples (which would silently invalidate
a before/after comparison) is visible, not silent. `diff` also warns if the
two samples being compared have different `target` values.

```bash
tools/memsample.sh list                      # show every running Batty (release/beta), pid + binary path
tools/memsample.sh pid --target release      # resolve one pid, or error clearly if not found
```

`sample`/`invariants` also accept a raw `--pid N` instead of `--target`, for
sampling any process (useful for the owner-label self-diagnosis above, or
comparing against a non-Batty app). This works correctly even against a
process with zero children — `pgrep -P` exits 1 (not 0) when there are no
children to list, which used to kill the whole script silently under this
harness's `set -e -o pipefail`; that's reachable through the documented
`--pid` option on any non-Batty process, and through any Batty instance
with zero live Terminal Sessions (a fresh Beta launch before opening its
first Tab — exactly experiments (a) and (c)'s baseline sample).

### Taking a sample

```bash
tools/memsample.sh sample --target release --tag baseline
# ... do something ...
tools/memsample.sh sample --target release --tag after
```

Writes, under `tools/memsamples/` by default (`--dir DIR` to override; the
directory is gitignored — samples are local run data, not repo content):

- `<tag>.json` — one sample as a standalone JSON object (all sizes in `*_bytes`, byte-exact from `footprint -p -f bytes`).
- `<tag>.kv` — the same data as flat `key=value` lines, including `schema` and `binary` (what `diff` reads back; avoids needing `jq`/a JSON parser in the script itself).
- `<tag>.census.txt` — the geometry-class census (`vmmap | grep ... | sort | uniq -c`), for class-level diffing.
- `samples.jsonl` — every sample ever taken in that directory, appended one JSON object per line. Samples from different schema versions can coexist in this file (each line self-describes its own `schema`); `diff` just won't compare across them.

`TAG` must match `^[A-Za-z0-9._-]+$` — it becomes both a filename and a bare
JSON string value, so a `"` or a `/` in it would write invalid JSON or a
stray path; the harness rejects it up front instead.

`owner_label` (in the JSON/`.kv`) records which quoted IOSurface-owner
string the sample matched against — see "Resolving the surface owner"
below. If it's empty and `batty_iosurfaces` is `0`, the sample's stdout
output already printed the full observed-owner histogram; check that before
trusting anything else in the sample. `binary` records the full resolved
path, so `diff` can (and does) warn if two samples share a `target` label
but came from different binaries on disk.

Each sample also prints the three invariants (see below) and a human-readable
summary to stdout.

### Resolving the surface owner (release vs beta are NOT interchangeable here)

The quoted string on an IOSurface's `vmmap` line (`'Batty'`, `'RenderBox'`,
`'Electron Framework'`, ...) is the **creating image's name, not the
process name**. It reads `'Batty'` for the release build only because
libghostty is statically linked into Batty's own executable. The Beta
build's Ghostty code lives in a separate `Batty Beta.debug.dylib`
(`otool -L`/`nm` confirm the `CAMetalLayer` references and `GhosttyTerminal`
symbols live in the dylib, not the 40 KB Beta stub executable) — so its
surfaces are owned by `'Batty Beta.debug.dylib'` or `'Batty Beta'`, never
`'Batty'`.

The harness never hardcodes an owner string. It derives candidates from the
resolved binary's own basename (`Batty`, `Batty Beta`) plus a
`.debug.dylib`-suffixed variant, and sums matches across both. **If neither
candidate matches anything (`batty_iosurfaces` comes back `0`), the sample
output prints the full observed owner-label histogram** — every quoted
label actually seen, with counts — so the fix is visible immediately
instead of a silent, wrong zero:

```
  [FAIL] IOSurfaces owned by this binary = layers x 3 : 0 IOSurfaces matched owner candidates ('Batty Beta', 'Batty Beta.debug.dylib')
         Observed owner labels in this process (count, quoted label) -- pick the real one from here:
             93 Batty
              3 RenderBox
              1 CoreUI image IOSurface
```

If you ever see this, the process being sampled is not what `--target`
claims it is (or the Beta build's dylib name changed) — treat it as a
harness-configuration problem, not a memory finding.

### Checking just the invariants

```bash
tools/memsample.sh invariants --target release
```

Prints, against a live pid, with actual numbers and the per-geometry
diagnostic table:

1. **IOSurface count owned by this binary == layers x 3** — `CAMetalLayer`'s default `maximumDrawableCount`. Exact equality; a real deviation.
2. **Surfaces shared with WindowServer, range `[layers, 2 x layers]`** — NOT exact equality. A 25-sample idle-process check (#0291 review round 1) found this oscillates on a ~1s timescale: one `CAMetalLayer` can briefly hold both a displayed front buffer and a committed-but-not-yet-retired one, so `layers` and `2 x layers` are both normal. The invariant is the range, and the harness prints a per-geometry `total` vs `ws` table alongside it — that table, not the scalar, is what makes a real deviation (as opposed to ordinary double-buffering) diagnosable. See the footnote in `issues/0285/investigation-live.md`.
3. **1040K grayscale-atlas region count == IOSurface count** — exact equality.

Invariants 1 and 3 have held exactly across every 25-sample idle-process run
taken so far (#0291 review rounds 1 and 2). Invariant 2's range has also
held every time, but **the split between `layers` and `layers + 1` is
itself unstable — don't expect a specific ratio, only the range**: three
independent 25-sample runs against the same idle release instance measured
13/12, 22/3, and 19/6 (`layers`/`layers + 1` counts). Only the
`[layers, 2 x layers]` bound is the invariant; the rate at which it sits at
one end or the other varies run to run and isn't itself meaningful. **A
harness that reports invariant 1 or 3 breaking, or invariant 2 falling
outside the range, is doing its job** — treat that as a finding to report,
never as a bug in the harness to paper over. If invariant 1 fails,
invariants 2 and 3 report `SKIP` rather than printing numbers computed from
an undefined `layers` value.

### Before/after diff

```bash
tools/memsample.sh diff baseline after
```

`diff` first checks that both samples carry the same `schema` and **dies**
if not (see the schema section above) — it never silently compares
incompatible field sets.

Reports, in order:

1. Sample metadata (timestamps, pids, targets, binaries) and a warning if
   the two samples are from different targets (release vs beta), different
   pids, or different binary paths under the same target label.
2. A metric-by-metric delta table: footprint, footprint peak, IOSurface,
   IOAccelerator, unmapped-graphics (each byte count + region count),
   threads, stack regions, live Terminal Session count, and the invariant
   inputs (`batty_iosurfaces`, `batty_windowserver_shared`,
   `atlas_1040k_count`, `layers`). **`batty_windowserver_shared` can move
   by ±1 (or more) between two samples of a completely idle process** —
   that's invariant 2's normal double-buffering oscillation (see above),
   not a memory change; the harness prints a reminder of this under the
   table.
3. **The geometry-class census diff** — a unified diff of the two
   `.census.txt` files. This is the part that matters most per
   `issues/0285/investigation-live.md`: a resize once showed a footprint
   delta of only +8 MB and an unchanged total surface count (93), while the
   class diff showed exactly what happened (820x962 66→60, a new 934x962
   class of 6 appeared). A tool that only diffs totals would have reported
   "nothing happened." Always check this section, not just the metric table.

## The four #0285 experiments

These are the umbrella's open questions (#0285 Notes / Description). Screen-
interaction steps (opening Tabs, calling `setSurfaceVisible`) can't be
scripted by this harness — it only samples a running process — so each
recipe below pairs a manual step with the sampling commands.

### (a) Atlas scaling — does opening a Tab grow the 1040K atlas by 3 (per-surface) or 0 (shared)? Gates #0287.

```bash
tools/memsample.sh sample --target beta --tag a-before
# manually: open exactly one new Tab in the Beta build
tools/memsample.sh sample --target beta --tag a-after
tools/memsample.sh diff a-before a-after
```

Look at `atlas_1040k_count` and `batty_iosurfaces` in the delta table: +3 on
each means per-surface ownership (confirms #0287's refactor won't reclaim
atlas memory); +0 means shared (refutes the premise, refactor is worth it).
The live data already found 93 atlases for 31 layers (exactly 3x), so +3 is
the predicted outcome — this experiment is the one-command falsification
test.

### (b) Occlusion reclaim — does `setSurfaceVisible(false)` drop the IOSurface region count? Decides #0288 vs #0293.

```bash
tools/memsample.sh sample --target beta --tag b-before
# manually / via debugger: call setSurfaceVisible(false) on a few Terminal Sessions
tools/memsample.sh sample --target beta --tag b-after
tools/memsample.sh diff b-before b-after
```

Watch `iosurface_regions` and `batty_iosurfaces`. A drop confirms #0288 is a
real reclaim (#0293 unnecessary). No drop means #0293's upstream ask (a real
GPU-resource release path) is the one that matters.

### (c) Teardown check — open 20 Tabs, close them, compare to baseline. #0289's outstanding acceptance test.

```bash
tools/memsample.sh sample --target beta --tag c-baseline
# manually: open 20 Tabs
tools/memsample.sh sample --target beta --tag c-opened
# manually: close all 20
tools/memsample.sh sample --target beta --tag c-closed
tools/memsample.sh diff c-baseline c-opened   # expect +60 batty_iosurfaces (20 layers x 3)
tools/memsample.sh diff c-baseline c-closed   # the real test: MUST return to baseline
```

If `c-closed` matches `c-baseline` on `batty_iosurfaces`/`iosurface_regions`
but not on `phys_footprint_bytes`, that points at "owned unmapped (graphics)"
accounting rather than a leak. If `batty_iosurfaces` stays elevated, teardown
is holding a `CAMetalLayer` past close (see #0289). Repeat the open/close
cycle 10x — a staircase in `batty_iosurfaces` across repeated `c-closed`-style
samples is the confirmation of a real leak versus a one-time accounting lag.

### (d) Content-driven vs frame-driven growth — `find /` vs `yes` for 10 min each.

```bash
tools/memsample.sh sample --target beta --tag d-idle
# manually: run `find / 2>/dev/null` in 2-3 panes for 10 minutes (novel content)
tools/memsample.sh sample --target beta --tag d-findslash
tools/memsample.sh diff d-idle d-findslash
# manually: stop, then run `yes` in 2-3 panes for 10 minutes (repeating content)
tools/memsample.sh sample --target beta --tag d-yes
tools/memsample.sh diff d-findslash d-yes
```

Atlas growth predicts `ioaccel_bytes`/`atlas_1040k_count` climbing for
`find /` and plateauing for `yes` (novel glyphs keep populating the atlas;
a small repeating buffer doesn't). A per-frame drawable leak predicts both
grow equally — watch `iosurface_regions` and `phys_footprint_bytes` for that
signature instead. This is also a case where the census diff matters:
watch whether new geometry classes appear or existing ones just grow their
count.

## Recommended target for driven experiments

Use `--target beta` (scheme `Batty (Beta)`, bundle id `co.sstools.Batty.beta`,
built with `SCHEME="Batty (Beta)" scripts/build.sh`) for experiments (a)-(d).
Its distinct bundle id means separate UserDefaults and workspace persistence,
so opening/closing 20 Tabs or driving Tab content doesn't touch the user's
release-instance sessions. Passive sampling (`sample`, `invariants`) of the
release instance is read-only and safe to run any time — just never target
it for the driven experiments.
