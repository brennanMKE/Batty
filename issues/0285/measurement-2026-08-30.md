# Live measurement — 2026-08-30

Attachment to umbrella [#0285](../0285.md). Measured against the **release**
instance (pid 9817, launched Fri 21 Aug 2026 15:38, ~9 d uptime) on a
2560×1664 Retina (2×) built-in display.

This sample was taken opportunistically: a close of 10 Terminal Sessions
happened mid-measurement, which turned a single footprint reading into a
**before/after natural experiment on teardown** — the one thing #0285 lists
as never having been observed live.

## Headline

Closing 10 Terminal Sessions returned **391 MB**, immediately and completely.
Teardown is not leaking. But **per-Terminal-Session cost did not move**, which
is the number the umbrella's acceptance criteria actually requires.

| | before | after | Δ |
|---|---|---|---|
| Terminal Sessions | 28 | 18 | −10 |
| `phys_footprint` | 1,433 MB | 1,042 MB | **−391 MB** |
| IOSurface | 653 MB / 356 rgn | 414 MB / 328 rgn | −239 MB |
| IOAccelerator (graphics) | 325 MB / 476 rgn | 246 MB / 356 rgn | −79 MB |
| Owned unmapped (graphics) | 116 MB | 92 MB | −24 MB |
| **graphics subtotal** | **1,094 MB (76%)** | **752 MB (72%)** | −342 MB |
| MALLOC_SMALL | 251 MB | 210 MB | −41 MB |
| large IOSurfaces (>1 MB) | 85 | 55 | −30 |
| **MB per Terminal Session** | **51.2** | **57.9** | — |

Baseline to beat (2026-07-31, pid 9870): 26 sessions, 1,472 MB, 56.6 MB/session.

## Finding 1 — teardown is clean (closes the #0285 open question)

The umbrella records: *"no Tab close was ever observed live, so the open/close
census is still the top untested question."* This sample is that observation.

Ten Terminal Sessions closed → **30 large IOSurfaces released**, exactly
3 per session, exactly the triple-buffered `CAMetalLayer` swap chain the
cost model predicts. Marginal cost **39.1 MB per Terminal Session**, landing
inside the 35–42 MB/layer band derived in #0288. No staircase, no residue:
the graphics subtotal fell by 342 MB of the 391 MB total.

**Deferring the free to ARC (the wart noted in #0289) is not costing anything
observable.** The memory came back promptly enough that a footprint sample
minutes later shows it fully returned.

## Finding 2 — #0288 removed the duplicate layers, but not the per-session floor

Drawable-size histogram (KB, sizes >1 MB, after):

```
  6 × 1968      (2 layers)
  3 × 2176   3 × 4368   3 × 5344   3 × 5472   3 × 5664   3 × 5904
  3 × 7520   3 × 7984   3 × 9616   3 × 10035  3 × 10138  3 × 10240
  3 × 11162  3 × 11571  3 × 13312  3 × 16794  (16 layers)
  1 × 44339    ← singleton, see Finding 3
```

**18 swap chains for 18 Terminal Sessions — a clean 1:1.** Compare July: 31
layers for 26 sessions, with 22 sharing one 820×962 geometry that at most 2
panes could occupy on screen. That duplication is gone; #0288's occlusion
signalling did its job on layer *count*.

What it did not do is free anything. Every one of those 18 swap chains is
sized to its Pane and resident, visible or not — and at most 2 Panes are on
screen at a time. Each geometry is distinct, so these are real per-Pane
drawables, not a shared pool. `setSurfaceVisible(false)` stops the render;
the drawables, glyph atlases, and render textures stay allocated for the life
of the process.

Net: **graphics fell from 76% to 72% of footprint, and cost per session went
from 51.2 to 57.9 MB.** The lever that works today is closing sessions, which
is not a fix.

## Finding 3 — one 43.3 MB IOSurface, unpaired

A single 44,339 KB region sits outside every triple. 43.3 MB / 4 B ≈ 11.35 M
pixels — **2.7× the entire 2560×1664 display**. It is not part of a swap
chain (singletons don't triple-buffer), so it is likely a window snapshot,
a system effect layer, or a genuinely oversized surface.

This is #0294-shaped but **not #0294**: that issue's premise is a 2× drawable
on a 1× display, and this host is Retina 2×, so #0294 cannot be confirmed or
refuted here. Worth identifying separately — it is 4% of footprint in one
region, and the in-process `TerminalMetalMetricsLogger` already has the hooks
to name its owner.

## Recommended work, cheapest first

### 1. Shrink hidden surfaces with `set_size` — Batty-side, unblocked

The #0293 reviewer established from that issue's own evidence that a drawable
is `width × height × 4` and that **a resize swaps the pool 1:1** (measured:
six 820×962 freed, six 934×962 allocated, net surface count unchanged). So
an embedder *can* shrink a hidden surface's swap chain without upstream help.

Nothing in `BattyKit/Sources` does this — `grep` for `setSize` /
`maximumDrawableCount` returns zero hits.

Call site is already built: `TerminalHostStore.updatePlacements` /
`setPlacement` (`TerminalHostStore.swift:406`) computes
`effectiveSurfaceVisible(placementVisible:windowVisible:)` and calls
`view.setSurfaceVisible(_:)`. Shrink on the same transition, restore on the
way back.

At 39 MB/session marginal cost and ~16 of 18 sessions hidden at any moment,
this is the largest available win that needs no upstream change. **Cost:
verify the restore path repaints correctly and that reflow doesn't corrupt
scrollback — a shrink is a resize, and a terminal resize reflows.** That risk
is the real work here, not the call itself.

### 2. File the #0293 upstream ask — blocked on a decision, not on engineering

`issues/0293/upstream-issue.md` is a reviewed, submission-ready draft asking
for (a) a lower `maximumDrawableCount` on occluded surfaces and (b)
free/reacquire of the swap chain on occlusion. **It has never been filed** —
no issue, PR, or comment against any upstream repo; the decision was reserved
for the user and is still open.

The repo-boundary question is answered and favourable: libghostty-spm patches
`src/renderer/metal/IOSurfaceLayer.zig` (`Patches/ghostty/0005-ios-metal-rendering.sh`)
— literally the swap-chain layer both asks target — so renderer changes
demonstrably land through that repo. Currently pinned at revision `b146b73`.

This is the only path to the structural fix: `ghostty.h` has
`ghostty_surface_set_occlusion` and `ghostty_surface_free` with nothing
between them, so there is no way to release a surface's GPU resources without
also killing its PTY.

### 3. Identify the 43.3 MB singleton

Extend `TerminalMetalMetricsLogger` to log `contentsScale` and
`drawableSize` per surface and match against the region census. If it belongs
to no Batty surface, record that with the evidence and move on — same
disposition #0294 prescribes for itself.

### 4. Re-run the scrolling repro — still untested

#0285's most diagnostically useful original observation is **+277 MB in
~11 minutes of ordinary scrolling with no Panes opened or closed**. The July
live instrumentation failed to reproduce it, but its sessions were idle
throughout, so it is untested rather than refuted. This sample is also from
an idle-ish instance and says nothing about it either.

Repro: `yes | head -1000000` in 2–3 Terminal Sessions, `footprint -p <pid>`
each minute for 10 minutes. If it reproduces, redraw-path allocation is a
separate defect from everything above and probably outranks it.

## Method notes

```sh
PID=$(ps -Ao pid=,comm= | awk '/Batty\.app\/Contents\/MacOS\/Batty$/{print $1; exit}')
footprint -p $PID | head -20
ps -Ao pid=,ppid=,comm= | awk -v p=$PID '$2==p' | wc -l   # Terminal Sessions
vmmap $PID | awk '/^IOSurface/{ ... }'                     # drawable histogram
```

Terminal Session count is the `login` child count — one PTY per Terminal
Session.

**`ps -o rss` remains unusable.** It read 266 MB against a real
`phys_footprint` of 1,433 MB — a 5.4× under-report on this sample, and 29×
on the original #0285 report. Every figure above is `phys_footprint`.
