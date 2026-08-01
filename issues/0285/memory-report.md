# Batty — memory usage report

**Date:** 2026-07-30
**App:** Batty 1.0.5 (build 20260618), `co.sstools.Batty`, ARM64
**Host:** macOS 26.4.1 (25E253), Apple Silicon, 32 GB RAM
**Process:** pid 17087, launched 2026-06-17 21:39:55 — **42 d 16 h uptime**

## Summary

A single Batty process holds a **8.4 GB physical footprint** (peak 8.5 GB) after
42 days of uptime with 111 open terminals. It is the largest process on the
machine — larger than `kernel_task` (3.2 GB), WindowServer (2.6 GB), and the
entire VS Code process tree.

**84% of that footprint is GPU/graphics memory**, not terminal buffers or
scrollback. The distribution strongly suggests render surfaces are being
allocated per pane and never released.

At ~65 MB of graphics memory per open terminal, the app is the dominant memory
consumer on an otherwise ordinary developer workload, and it pushed the system
into kernel memory pressure level 2.

## Measurement note — `ps` under-reports this by 29×

| Tool | Reading |
|---|---|
| `ps -o rss` | **287 MB** |
| `top -stats mem` | 8439 MB |
| `footprint -p` | **8546 MB** |
| `vmmap` physical footprint | 8.4 GB |

RSS excludes compressed and swapped pages. Under memory pressure macOS compresses
idle pages, so RSS *systematically under-reports the worst offenders* — precisely
when accurate numbers matter most. 1.9 GB of Batty's footprint was in the
compressor at the time of measurement.

**Use `phys_footprint` (via `footprint`, `vmmap`, or `top`'s MEM column) for any
memory work on this app.** RSS-based monitoring missed this entirely for weeks.

## Footprint breakdown

From `footprint -p 17087`:

| Category | Dirty | Regions | Avg/region | Share |
|---|---|---|---|---|
| **IOSurface** | **5331 MB** | 755 | 7.06 MB | **62%** |
| **IOAccelerator (graphics)** | **1414 MB** | 2651 | 0.53 MB | **17%** |
| MALLOC_SMALL | 886 MB | 325 | 2.73 MB | 10% |
| Owned physical footprint (unmapped) (graphics) | 409 MB | 4028 | 0.10 MB | 5% |
| app-specific tag 1 | 370 MB | 605 | 0.61 MB | 4% |
| stack | 53 MB | 1390 | 39 KB | <1% |
| MALLOC_LARGE | 21 MB | 2 | — | <1% |
| page table | 9.6 MB | 1 | — | <1% |

**Graphics total: 7154 MB — 84% of the footprint.**

Context from `vmmap -summary`:

```
Physical footprint:         8.4G
Physical footprint (peak):  8.5G
ReadOnly portion of Libraries: Total=1.8G resident=575.9M(31%) swapped_out_or_unallocated=1.2G(69%)
Writable regions: Total=13.4G written=452.4M(3%) resident=392.7M(3%) swapped_out=1.4G(10%) unallocated=11.6G(87%)
```

## Per-terminal math

With 111 open terminals:

| Metric | Value |
|---|---|
| IOSurfaces per terminal | **6.8** |
| Graphics memory per terminal | **~64.5 MB** |
| Threads | 662 (≈6 per terminal) |
| Stack regions | **1390** |

Two ratios stand out:

1. **6.8 IOSurfaces per pane at 7.06 MB each.** A terminal pane needs a small
   number of drawable surfaces. Seven persistent 7 MB surfaces per pane suggests
   surfaces are retained per redraw, per resize, or per scroll position rather
   than reused from a pool.

2. **1390 stack regions vs. 662 live threads.** Roughly 728 stack regions exist
   with no corresponding thread. Thread stacks appear not to be reclaimed on
   thread exit.

## Hypotheses for investigation

Ordered by expected payoff. These are inferences from the region data, not
confirmed diagnoses — the app source will settle each quickly.

### 1. IOSurface retention per pane (≈5.3 GB)
755 surfaces for 111 panes. Worth checking:
- Are surfaces released when a pane is **closed**, or only when the app quits?
  If 755 includes surfaces from panes closed days ago, this is a straight leak.
- Are surfaces reallocated on **resize** or **font change** without freeing the
  previous one?
- Is there a **drawable/surface pool**, or does each redraw path allocate?
- Do **backgrounded / occluded** panes keep full-size surfaces? Panes not visible
  don't need a live drawable.

### 2. IOAccelerator region count (≈1.4 GB across 2651 regions)
2651 regions averaging 0.53 MB reads like per-pane texture or buffer allocations
(glyph atlases, layer backing stores). Check whether glyph atlases are shared
across panes or duplicated per pane — 111 copies of a shared atlas would explain
the magnitude.

### 3. "Owned physical footprint (unmapped) (graphics)" — 4028 regions, 409 MB
Memory still **charged to the process** but no longer mapped. Typically GPU
allocations released on the CPU side while the kernel still bills them. High
region count with low average size suggests many small allocations not fully
returned. Often a symptom of #1/#2 rather than an independent leak.

### 4. Thread stack accumulation (1390 regions, 662 threads)
Only 53 MB, so low priority for memory — but the ~728 orphaned stack regions
point at a thread lifecycle issue that may matter for other reasons.

### 5. Address space fragmentation
`Writable regions: Total=13.4G ... unallocated=11.6G (87%)` and a 625 GB VSZ.
Not a footprint problem directly, but a very large sparse address space with
~23,000 regions adds page-table overhead (9.6 MB) and slows VM operations.

## Suggested reproduction

Growth is observable within ~10 minutes of ordinary use (see *Impact* below), so
start with the fast check:

0. **Fastest repro:** with panes already open, generate continuous scrolling
   output (`yes | head -1000000`, or `find / 2>/dev/null`) in 2–3 panes and sample
   `footprint` every minute for 10 minutes. A steady climb with no pane
   open/close confirms redraw-path allocation.

Then the lifecycle tests:

1. Open ~20 panes. Record `footprint -p $BATTY`.
2. Close all 20. Record again — **does the footprint return to baseline?**
   If not, pane teardown is leaking, which is the fastest thing to confirm.
3. Repeat open/close 10×. A staircase that never returns to baseline confirms #1.
4. Separately: open 20 panes, resize the window repeatedly, and watch the
   IOSurface region count in `footprint`.
5. Long-run: leave 50+ panes open for 24 h with light activity and sample
   hourly. Growth without interaction points at redraw-path allocation.

Useful one-liners:

```bash
# Get the pid. NOTE: `pgrep Batty` returns nothing on this machine (it works for
# other apps, e.g. `pgrep -x Safari`), so match on the full path instead.
BATTY=$(ps -Ao pid=,comm= | awk '/Batty\.app\/Contents\/MacOS\/Batty$/{print $1; exit}')

# total footprint
footprint -p $BATTY | tail -4

# region counts by category
footprint -p $BATTY | head -20

# just the graphics regions
vmmap -summary $BATTY | grep -E "IOSurface|IOAccelerator"

# watch it grow
while :; do
  printf "%s  %s\n" "$(date +%H:%M:%S)" \
    "$(footprint -p $BATTY | awk '/phys_footprint:/{print $2, $3}')"
  sleep 300
done
```

## Suggested fixes

1. **Release IOSurfaces on pane close.** Highest expected payoff; also the easiest
   to verify with step 2 above.
2. **Pool and reuse drawables** instead of allocating per redraw/resize.
3. **Evict surfaces for occluded or backgrounded panes**, reallocating on
   re-display. With 111 panes, only a handful are ever visible.
4. **Share glyph atlases across panes** rather than per-pane copies.
5. **Cap or age out** retained surfaces — a ceiling would have bounded this at
   something far below 5.3 GB.
6. **Reclaim thread stacks** on thread exit.

## Impact observed on this machine

Chronology from a 32 GB host running an otherwise normal developer workload:

| Date | Note |
|---|---|
| 2026-06-17 | Batty launched |
| 2026-07-26 | Batty footprint already ~8.4 GB (unnoticed — RSS reported 254 MB) |
| 2026-07-30 11:36 | Kernel pressure level 2; Batty 8443 MB, largest process |
| 2026-07-30 13:36 | Pressure 2 sustained; swap grew to 23.2 GB |
| 2026-07-30 13:42 | Pressure back to 1 after closing ~55 Safari tabs — **Batty unchanged at 8439 MB** |

After the unrelated Safari tabs were closed, Batty accounted for roughly **38% of
all memory in use** on the system.

**It also grows measurably under light use.** Sampled during a single session of
ordinary terminal activity on 2026-07-30:

| Time | phys_footprint |
|---|---|
| 13:36 | 8459 MB |
| 13:42 | 8439 MB |
| 13:44 | 8546 MB |
| 13:47 | **8716 MB** (peak 8801) |

**+277 MB in about 11 minutes**, with no panes opened or closed — only scrolling
and command output in existing terminals. It never gave any of it back.

This is the most diagnostically useful observation in this report: growth without
pane lifecycle events points at the **redraw path** allocating surfaces rather
than reusing them, which raises the priority of hypotheses #1 and #2 and makes
the leak reproducible in minutes rather than days.

## Environment

```
macOS       26.4.1 (25E253)
Hardware    Apple Silicon, 32 GB
Batty       1.0.5 (20260618)
Uptime      Batty 42 d, system 57.8 d
Panes       111 child processes
Threads     662
```

---
*Measured with `footprint`, `vmmap`, and `top`. Raw system history:
`~/Developer/Memory/memsnap.jsonl`.*
