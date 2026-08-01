# #0285 — Live-process investigation (instrumentation half)

**Target:** Batty 1.0.5 (build 20260618), pid 9870, launched 2026-07-24 14:45:11 — **7 d 8 h uptime** at sampling.
**Host:** single 1920×1080 display at **1× backing scale** (non-Retina). Window frame 1873×1050; terminal content area 1645×962 pt.
**Method:** passive read-only sampling (`footprint`, `vmmap`, `vmmap -summary`, `ps -M`, `nm`) every 2 min for 20 min, 2026-07-31 22:57:59 → 23:18:13. The process was never signalled, suspended, or interacted with. `leaks` and `heap` were deliberately **not** run (both suspend the target).

## Summary

- **The footprint did not grow.** Over 20 minutes of ordinary use it moved 1472 → 1475 MB (+3 MB, ≈ +9 MB/h) and was **not monotonic** — it dipped below baseline in 5 of 11 samples. The report's "+277 MB in 11 minutes, never gave any of it back" is **not reproduced** on this instance. `vmmap` also shows **peak 2.1 GB vs current 1.44 GB**, so this process has already returned ~660 MB to the system.
- **IOSurface count is exactly 3 × the number of live terminal layers, and it is stable.** 93 `'Batty'`-owned IOSurfaces at both t0 and t1 → **exactly 31.00 layers**, with **exactly 31 (33.3%) shared with WindowServer** in both samples. That 3:1 ratio is the signature of `CAMetalLayer` at its default `maximumDrawableCount = 3`. This is *not* redraw-path accumulation.
- **A pane resize happened mid-window and was a clean 1:1 swap.** Two panes went 820→934 px wide: six 820×962 drawables were **freed** and six 934×962 drawables allocated; total surfaces stayed at 93/118 regions. **Resize churn does not leak.**
- **The real driver is per-Terminal-Session cost, not time.** ~35 MB of graphics memory per terminal layer, and layers exist for Terminal Sessions that are *not on screen* (22 of the 31 layers share one identical half-pane geometry that at most 2 panes can occupy at once).
- **Glyph atlases are duplicated per surface, not shared.** 93 regions of exactly 1040 K and 94 of exactly 272 K — arithmetically 1024×1024×1 B and 256×256×4 B plus one 16 K page each. 93 = 31 layers × 3. That is **119 MB of glyph atlas** for 26 terminals.
- **The ~728 orphaned thread stacks are a counting artifact, not a leak.** `footprint`'s `stack` category counts the guard page as a separate region: 125 live threads → 125 `Stack` + 125 `STACK GUARD` + 6 misc = 256 regions. Ratio 2.05 here, 2.10 in the report.

## Sample table

phys_footprint in MB; `iosurf`/`ioaccel`/`unmapped_gfx` are dirty MB and region counts from `footprint -p 9870`. Peak read from `vmmap -summary`.

| # | time | footprint | peak | IOSurface MB / n | IOAccel MB / n | unmapped gfx MB / n | MALLOC_SMALL MB | stack MB / n | threads | Terminal Sessions |
|---|---|---|---|---|---|---|---|---|---|---|
| 00 | 22:57:59 | 1472 | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.6 / 254 | 125 | 26 |
| 01 | 23:00:00 | 1472 | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.6 / 256 | 125 | 26 |
| 02 | 23:02:02 | 1472 | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.7 / 258 | 126 | 26 |
| 03 | 23:04:03 | **1471** | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.7 / 256 | 125 | 26 |
| 04 | 23:06:05 | 1472 | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.6 / 256 | 125 | 26 |
| 05 | 23:08:06 | 1472 | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.6 / 256 | 125 | 26 |
| 06 | 23:10:08 | **1471** | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.6 / 256 | 125 | 26 |
| 07 | 23:12:09 | **1471** | 2.1 G | 377 / 118 | 465 / 563 | 248 / 717 | 252 | 9.7 / 258 | 126 | 26 |
| 08 | 23:14:11 | 1480 | 2.1 G | 379 / 118 | 465 / 563 | 248 / 717 | 254 | 9.7 / 260 | 127 | 26 |
| 09 | 23:16:12 | 1476 | 2.1 G | 379 / 118 | 465 / 563 | 248 / 717 | 254 | 9.7 / 256 | 125 | 26 |
| 10 | 23:18:13 | 1475 | 2.1 G | 379 / 118 | 465 / 563 | 248 / 717 | 254 | 9.6 / 256 | 125 | 26 |

**Growth rate: +3 MB / 20 min = +9 MB/h. Not monotonic** (samples 03, 06, 07 below baseline; 09 and 10 below sample 08). The +8 MB step at 23:14 coincides with the pane resize described below and is entirely accounted for by it (6 × (3552−3136) KB = +2.4 MB IOSurface, +2 MB MALLOC_SMALL).

Long-run framing, for comparison with the original report:

| | this process | reported process |
|---|---|---|
| uptime | 176 h | 1024 h |
| Terminal Sessions | 26 | 111 |
| footprint | 1472 MB | 8546 MB |
| MB per hour of uptime | **8.35** | **8.35** |
| MB per Terminal Session | **56.6** | **77.0** |
| graphics share | 74% | 84% |
| threads per Terminal Session | 4.8 | 6.0 |
| stack regions / threads | 2.05 | 2.10 |

The MB/hour figures matching to three digits is coincidence, but the per-session figures being within 1.4× of each other across a 6× difference in uptime is the load-bearing number: **footprint tracks session count far better than it tracks time.**

**Measurement trap confirmed:** `ps -o rss` = 210 MB vs `footprint` = 1472 MB — a **7.0× under-report** on this instance (29× on the reported one; the gap scales with how much has been compressed).

## Per-hypothesis verdict

### H1 — IOSurface retention per Terminal Session: **partly confirmed, mechanism corrected**

The report asked whether ~7 MB × N is "one drawable per surface at window resolution" or "several retained per surface." **Neither.** The measured answer:

| geometry (px) | region size | count | layers (n/3) | note |
|---|---|---|---|---|
| 820×962 | 3136 K | 66 → 60 | 22 → 20 | half-width pane, current geometry |
| 934×962 | 3552 K | 0 → 6 | 0 → 2 | appeared at t1 (resize) |
| 1645×962 | 6208 K | 6 | 2 | full content-area pane |
| 1641×922 | 5936 K | 6 | 2 | |
| 1644×857 | 5520 K | 3 | 1 | |
| 820×461 | 1504 K | 6 | 2 | half-width, half-height pane |
| 820×408 | 1328 K | 3 | 1 | |
| **3290×1924** | **24.2 M** | **3** | **1** | **2× the content area on a 1× display — 72.6 MB** |
| 362×434 | 656 K | 3 | 1 | `'RenderBox'` (SwiftUI), not a terminal |
| **total `'Batty'`** | | **93** | **31.00** | identical at t0 and t1 |

The decisive numbers:

- **One drawable = exactly width × height × 4.** 820 × 962 × 4 = 3,155,360 B; the region is 3136 K = 3,211,264 B (row-aligned to 832 px). The arithmetic closes to within one page. There is no bloat inside a drawable.
- **Exactly 3 drawables per layer.** 93 / 3 = 31.00, and exactly 31 surfaces (33.3%) are `shared with WindowServer[607]` — one per layer, the front buffer. Both ratios held identically across two samples 20 minutes apart. This is `CAMetalLayer`'s default triple buffering, not accumulation.
  **Footnote (2026-08-01, #0291 review rounds 1–2):** the 93/31.00 IOSurface-count ratio re-confirmed exactly across three independent 25-sample runs, but the "31 shared with WindowServer" figure did not — it oscillates 31↔32 on a ~1 s timescale, while every other geometry class stayed pinned. One `CAMetalLayer` intermittently has a second drawable held by WindowServer (a fully-swapped committed-but-not-yet-retired buffer alongside the displayed front buffer) — ordinary compositor behavior, not a leak. The *split* between the two states is itself unstable and not a meaningful number: three separate 25-sample runs against the same idle release instance measured 13/12, 22/3, and 19/6 (`layers`/`layers + 1` counts) — anywhere from roughly 50/50 to roughly 88/12. At n=2 (this section's original two samples) the single "held identically" observation was a coin flip, not a firm invariant: treat "shared with WindowServer" as bounded by `[layers, 2 × layers]`, not exactly `layers × 1`, and don't expect a particular rate within that range. `tools/memsample.sh` (#0291) implements it as a range check with a per-geometry total-vs-WindowServer table for exactly this reason.
- **Surfaces are freed on resize.** Between t0 and t1 the user widened a split. 820×962 went 66 → 60 and a new 934×962 class appeared with exactly 6. Net surface count unchanged at 93. The sub-hypothesis "reallocated on resize/font change without freeing the predecessor" is **refuted**.
- **Surface IDs are recycled, not monotonic.** SurfaceID `0x13b` was an 820×962 surface at t0 and a 934×962 surface at t1. Max slot index was `0x45b` at *both* samples. So the allocator reuses slots — but the high-water slot index of 1115 against 97 live surfaces indicates this process has previously held far more concurrent surfaces than it does now, consistent with the 2.1 GB peak.

**What is confirmed** is the occlusion sub-hypothesis. The window content area is 1645 pt wide; a half-width pane is (1645−5)/2 = **820** pt — exactly the dominant geometry. **At most 2 panes of 820×962 can be on screen at once, yet 22 such layers existed.** Layers are retained for Terminal Sessions that are not visible. 31 layers vs 26 live shells means layer count tracks *existing* Terminal Sessions, not visible ones.

**Anomaly worth a follow-up:** the 3290×1924 class is exactly 2× the 1645×962 content area, on a display with backing scale 1.0. Three of them = **72.6 MB, 5% of the whole footprint**, for one layer rendered at 4× the pixels it can display. Could not be determined from outside the process whether this is a mis-set `contentsScale`, a window snapshot, or a system effect layer.

### H2 — IOAccelerator: glyph atlases duplicated per surface: **confirmed**

IOAccelerator (graphics) = 465 MB across 563 regions. Broken down by size class:

| size class | count | total | identification |
|---|---|---|---|
| **1040 K** | **93** | **94.5 MB** | 1024×1024×1 B grayscale glyph atlas + one 16 K page |
| **272 K** | **94** | **25.0 MB** | 256×256×4 B color/emoji atlas + one 16 K page |
| 4.5–6.0 MB | 68 | 326 MB | per-surface Metal render textures; appear in groups of 3, ~23 groups, sizes varying per surface in 16 K steps |
| ≤368 K other | 308 | ~18 MB | pipeline state, small buffers |

The atlas counts are the finding. 1040 K − 1024 K = 16,384 B exactly (one page of Metal descriptor); 272 K − 256 K = 16,384 B exactly. And **93** is precisely the `'Batty'` IOSurface count, i.e. **31 layers × 3**. Both counts were byte-identical at t0 and t1 and across the resize.

So each terminal surface carries its own 1024² grayscale atlas and 256² color atlas, replicated 3× for the frame pipeline: **3.85 MB of glyph atlas per Terminal Session, none of it shared.** For 111 terminals that is ~427 MB of duplicated atlas; the report's "111 copies of a shared atlas would explain the magnitude" is directionally right, and the mechanism is now pinned to a specific pair of allocation sizes a code reader can grep for.

### H3 — "Owned physical footprint (unmapped) (graphics)": **inconclusive, but bounded and stable**

248 MB across 717 regions (avg 354 KB), **byte-identical in all 11 samples**. It is stable rather than growing, which is inconsistent with it being an independent leak. Because these regions are unmapped by definition they carry no `vmmap` detail line, so they cannot be attributed further from outside the process. Treating it as a symptom of H1/H2 remains the best available reading, and its perfect stability over 20 minutes weakens it as a standalone concern.

### H4 — ~728 orphaned thread stacks: **refuted**

`footprint`'s `stack` category counts a thread's guard page as a second region. From the full `vmmap`:

```
Stack            129 regions   (125 with a "thread N" detail line)
STACK GUARD      125 regions   ("stack guard for thread N")
Stack Guard        1 region
Stack (reserved)   1 region
                 ---
                 256  = exactly the 256 the footprint table reports
```

125 live threads → 125 named stacks → **1:1, zero orphans**. The ratio of stack regions to threads is 2.05 here and 2.10 in the report — the same artifact, not a different process behaving differently. The reported "1390 stack regions vs 662 threads" resolves to 662 stacks + 662 guards + 66 misc. There is no thread-stack leak to fix.

### H5 — Address-space fragmentation: **refuted as a footprint concern**

`Writable regions: Total=2.9G written=254.4M(9%) unallocated=2.3G(79%)`, 9,871 total regions, page table 2.66 MB. The 79%-unallocated figure is dominated by thread stack *reservations*: `Stack` has 1.9 G virtual against 2.8 MB dirty (125 threads × 16 MB reserved). That is normal pthread behaviour on macOS, not fragmentation. `ps -o vsz` reports 419 GB, which is the same reservation accounting inflated further — the report's "625 GB VSZ" is this artifact, not real address space consumption.

## Attribution

This is the part that decides where follow-ups get filed.

**libghostty is statically linked into the Batty binary** (`/Applications/Batty.app/Contents/MacOS/Batty`, 26.6 MB; the only bundled framework is Sparkle). So there is no dylib boundary to attribute across — but the Swift symbol table gives it directly:

```
_$s15GhosttyTerminal03AppB4ViewC10metalLayerSo07CAMetalF0CSgvg
  = GhosttyTerminal.AppTerminalView.metalLayer.getter : CAMetalLayer?
_OBJC_CLASS_$_CAMetalLayer   (undefined — imported)
```

`CAMetalLayer` is referenced by exactly one thing in the binary: **`GhosttyTerminal.AppTerminalView`**, which is the external `libghostty-spm` package, not Batty's own code. Batty's own source contributes no Metal layer. `AGXMetalG16X`, `Metal.framework`, `IOAccelerator.framework` and `QuartzCore` are all loaded; the `IOSurface` regions are named `'Batty'` (the process) and the only 1:3-ratio, BGRA, pane-geometry consumer in the address space is that layer.

The boundary is therefore clean:

| owned by | what | evidence |
|---|---|---|
| **Upstream (libghostty-spm / `GhosttyTerminal`)** | 3 drawables per surface (`CAMetalLayer.maximumDrawableCount` left at its default of 3) | 93 surfaces / 31 layers = exactly 3.00; exactly 1/3 held by WindowServer |
| **Upstream** | per-surface 1024² grayscale + 256² color glyph atlases, replicated 3×, **not shared between surfaces** | 93 × 1040 K and 94 × 272 K regions, exact byte arithmetic |
| **Upstream** | per-surface Metal render textures, 4.5–6.0 MB, in groups of 3 | 68 regions ≥ 4 MB ≈ 23 groups × 3 |
| **Batty** (`TerminalHostStore`) | **how many `AppTerminalView`s (and therefore `CAMetalLayer`s) exist at once** — one per Tab, including hidden background Tabs | 22 layers at a geometry only 2 panes can occupy; 31 layers for 26 live shells |
| unclear | the 3290×1924 (2×) content-area layer, 72.6 MB on a 1× display | geometry arithmetic only; the `contentsScale` is not visible from outside |

**Per-Terminal-Session cost model, measured at 820×962:**

| component | cost |
|---|---|
| 3 × IOSurface drawable (820×962×4) | 9.19 MB |
| 3 × grayscale glyph atlas (1024²) | 3.05 MB |
| 3 × color glyph atlas (256²) | 0.80 MB |
| Metal render textures (326 MB / 31 layers) | ~10.5 MB |
| unmapped graphics (248 MB / 31) | ~8.0 MB |
| **graphics total** | **~35 MB per layer / ~42 MB per Terminal Session** |

Total graphics = 377 + 465 + 248 = **1090 MB, 74% of the 1472 MB footprint**.

The practical consequence: **the single highest-leverage change is Batty-side and it is to reduce the number of live `CAMetalLayer`s**, because everything in the table above multiplies by that count. Every per-surface constant in the table is upstream, and reducing any of them (shared atlases, `maximumDrawableCount = 2` for occluded surfaces) is a libghostty-spm issue. Two separate follow-ups, and the Batty one is the bigger lever.

## Reproduction recipe

The cheapest reliable check needs **no waiting and no interaction** — it is a single read-only command that tests the layer-count hypothesis directly:

```bash
BATTY=$(ps -Ao pid=,comm= | awk '/Batty\.app\/Contents\/MacOS\/Batty$/{print $1; exit}')

# Layer census: geometry, count, and derived layer count
vmmap $BATTY | grep -oE "[0-9]+x[0-9]+ \([A-Z0-9]+\) [0-9.]+[KM]  '[^']*'" | sort | uniq -c | sort -rn

# The two invariants that must hold
echo "Batty IOSurfaces: $(vmmap $BATTY | grep -c "SurfaceID.*'Batty'")   (expect layers x 3)"
echo "held by WindowServer: $(vmmap $BATTY | grep "SurfaceID.*'Batty'" | grep -c WindowServer)   (expect exactly layers x 1)"
echo "grayscale atlases 1040K: $(vmmap $BATTY | grep -cE '^IOAccelerator \(graphics\).*\[ *1040K')   (expect = IOSurface count)"
echo "live Terminal Sessions:  $(pgrep -P $BATTY | wc -l)"
```

**Predicted signature if the diagnosis is right:** `'Batty'` IOSurface count ≈ 3 × (total Tabs across all Sessions, visible or not), grayscale-atlas count equal to the IOSurface count, and the dominant geometry repeated many more times than can be on screen. Any future session can confirm or falsify this in one command against a live instance — no 42 days, no scrolling, no touching the user's terminals.

For the growth question specifically, the cheap version is the same census run twice around whatever activity you want to test, comparing the *counts*, not the total:

```bash
vmmap $BATTY | grep -oE "[0-9]+x[0-9]+ .* '[^']*'" | sort | uniq -c > /tmp/before.txt
# ... do the thing ...
vmmap $BATTY | grep -oE "[0-9]+x[0-9]+ .* '[^']*'" | sort | uniq -c > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

This is how the resize was caught: the diff shows exactly which geometry class gained and which lost, which a footprint total cannot.

## What could not be tested, and why

Everything below requires either restarting Batty or driving the user's live Terminal Sessions, both of which were out of bounds. These are for the user to run manually.

**1. Teardown-to-baseline (the report's step 2 — the highest-value untested item).** Resize was observed to free drawables 1:1, but no Tab close was observed, so this cannot say whether `releaseTerminalView(forTabID:)` actually drops the `CAMetalLayer`. This is the test that distinguishes "bounded per-session cost" from "straight leak":

```bash
BATTY=$(ps -Ao pid=,comm= | awk '/Batty\.app\/Contents\/MacOS\/Batty$/{print $1; exit}')
census() { vmmap $BATTY | grep -c "SurfaceID.*'Batty'"; footprint -p $BATTY | awk '/Footprint:/{print $3, $4}'; }

census                       # baseline
# ... open 20 Tabs by hand ...
census                       # expect +60 surfaces (20 layers x 3)
# ... close all 20 ...
census                       # MUST return to baseline. If not, teardown leaks.
```

Repeat the open/close cycle 10× — a staircase in the surface count is the confirmation.

**2. The active-scroll repro (the report's step 0).** The user's sessions were idle for the whole 20-minute window, so only the idle case was measured, and idle is flat. Reproducing the reported +277 MB/11 min requires generating output, which was not permitted. To run it manually:

```bash
# in 2-3 Batty panes:  yes | head -100000000
# in a separate shell:
BATTY=$(ps -Ao pid=,comm= | awk '/Batty\.app\/Contents\/MacOS\/Batty$/{print $1; exit}')
for i in $(seq 12); do
  printf "%s  %s  surfaces=%s\n" "$(date +%H:%M:%S)" \
    "$(footprint -p $BATTY | awk '/Footprint:/{print $3, $4}')" \
    "$(vmmap $BATTY | grep -c "SurfaceID.*'Batty'")"
  sleep 60
done
```

The surface count is the important column. If the footprint climbs while the surface count stays flat, the growth is *not* in the render surfaces and hypothesis 1 is wrong for that scenario too.

**3. Restart-to-baseline.** What a fresh Batty with 26 sessions costs could not be established, so "26 sessions cost 1472 MB" cannot be separated from "26 sessions cost less, plus 7 days of drift." The 2.1 GB peak vs 1.44 GB current proves the process *can* shed memory, but not that it sheds all of it. Running test 1 from a fresh launch settles this.

**4. `leaks` / `heap` / `malloc_history`.** Not run — all three suspend the target and would have stalled the user's terminals. MALLOC_SMALL is 252 MB with 20% fragmentation across 532,244 allocations (from `vmmap`'s malloc zone table), which is worth a `leaks` pass at some point, but it is 17% of the footprint against graphics' 74%.

**5. The 2× content-area layer.** Determining whether the 3290×1924 surfaces are a mis-set `contentsScale`, a window snapshot, or a system effect needs in-process inspection (a debugger or an `NSView.layer.contentsScale` log), not `vmmap`.

---

**One caveat on the headline finding.** The strongest claims here — 3 drawables per layer, atlases not shared, resize frees cleanly — rest on region-count arithmetic that held exactly across two samples. They are consistent and the arithmetic is tight, but they are inferences from outside the process.
