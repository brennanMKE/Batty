# No way to release a surface's GPU resources short of `ghostty_surface_free` — occlusion appears to only gate the render loop

## Problem

Across the surface lifecycle block of the public API (`ghostty_surface_*`, `ghostty.h:1117-1187`), there is no call that releases a surface's GPU-side resources (swap-chain IOSurfaces, glyph-atlas textures) independent of destroying the surface, and no call to reacquire them afterward. The only two relevant calls are `ghostty_surface_set_occlusion` and `ghostty_surface_free`. For an embedder holding many concurrent surfaces where only a few are ever visible at once (a terminal multiplexer with tabs/panes, or any host keeping background surfaces alive so they can resume instantly), that means graphics memory scales with the number of *open* surfaces rather than the number of *visible* ones, with no lever to bound it short of destroying a surface and its PTY.

We're filing two asks, cheapest first, both grounded in the same investigation:

1. Lower the swap-chain's buffer count for non-visible surfaces (small, additive).
2. Free the swap chain on occlusion (or provide an explicit release/reacquire pair) (larger, structural).

This report is against tag **1.3.2** (commit `b146b73`, vendoring ghostty `35e1a01`).

## Evidence

**The public API has nothing between "pause rendering" and "destroy everything."** The `ghostty_surface_*` lifecycle block, `ghostty.h:1117-1187`:

```c
GHOSTTY_API ghostty_surface_t ghostty_surface_new(...)      // 1119
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t)    // 1121
...
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t) // 1130
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t)    // 1131
GHOSTTY_API void ghostty_surface_set_content_scale(...)     // 1132
GHOSTTY_API void ghostty_surface_set_focus(...)             // 1133
GHOSTTY_API void ghostty_surface_set_occlusion(...)         // 1134
GHOSTTY_API void ghostty_surface_set_size(...)              // 1135
...
```

A search of the entire header (1,227 lines) for `release`, `suspend`, `pause`, `drawable`, `swap`, `reacquire`, and `gpu` turns up nothing surface-lifecycle-related — only unrelated enum cases like `GHOSTTY_MOUSE_RELEASE` and `GHOSTTY_KEY_PAUSE`. There is no drawable-count knob, no swap-chain release call, and no reacquire call anywhere in the public API.

**The Swift wrapper doesn't hide any extra capability here either — both calls are thin 1:1 passthroughs.** `Sources/GhosttyTerminal/Surface/TerminalSurface.swift`:

```swift
// :201-205
func setOcclusion(_ visible: Bool) {
    guard let s = surface else { return }
    TerminalDebugLog.log(.lifecycle, "surface occlusion visible=\(visible)")
    ghostty_surface_set_occlusion(s, visible)
}

// :397-403
func free() {
    guard !hasBeenFreed, let s = surface else { return }
    TerminalDebugLog.log(.lifecycle, "surface free")
    hasBeenFreed = true
    surface = nil
    ghostty_surface_free(s)
}
```

Neither does anything beyond the direct C call — confirming the gap is in the underlying library, not something the Swift layer is failing to surface.

**The wrapper never touches drawable-pool sizing at all.** `grep -rn "maximumDrawableCount\|nextDrawable\|IOSurface" Sources/` returns zero API usages — every hit (four, all in `AppTerminalView+Lifecycle.swift`/`TerminalSurfaceCoordinator.swift`) is inside a code comment, not a call site. Drawable pool sizing is entirely internal to the vendored renderer; nothing in the Swift wrapper could adjust it even if an embedder wanted to.

**Symbol-table inspection of a shipped binary that statically links this library** shows `CAMetalLayer` referenced by exactly one type in the application binary and its statically linked libraries: `GhosttyTerminal.AppTerminalView` (this library's own view class). The embedding application contributes no Metal/drawable code of its own — every drawable-related symbol we can find traces to this library and the vendored Ghostty renderer, which is consistent with `AppTerminalView`'s own lifecycle code: it creates one `CAMetalLayer` per view in `commonInit` (`Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView.swift:56-67`), but the renderer can swap `self.layer` to its own `IOSurfaceLayer` once attached (documented in this repo's own comment at `AppTerminalView+Lifecycle.swift:174-182`: "The render pipeline can swap `self.layer` to an IOSurfaceLayer for IOSurface-backed compositing").

**Measured signature (our own multiplexer, single 1× display, idle sampling, read-only `footprint`/`vmmap` over 20 minutes, 11 samples 2 minutes apart):** the app's own IOSurface count was exactly 3× the live terminal-view (layer) count at both ends of that window — 93 surfaces / 31 layers = 3.00, re-confirmed in a separate run of three independent 25-sample passes against the same instance — and a live pane resize mid-window was a clean 1:1 swap (six 820×962 drawables freed, six 934×962 allocated, net count unchanged), not accumulation. That 3:1 ratio is the signature of a triple-buffered swap chain (`CAMetalLayer`'s own default `maximumDrawableCount` is 3; whether the effective renderer-side buffer count is literally that property or an equivalent internal constant in the `IOSurfaceLayer` path we can't tell from outside the process, since the swap happens inside this library). Of the 31 layers, 22 shared one identical half-pane geometry, of which at most 2 could occupy that specific geometry on screen at once — so at least 20 of the 31 layers were demonstrably not visible, and every one of them held a full 3-drawable pool regardless (the true hidden count across all 31 layers, spanning several geometries, wasn't separately bounded). On that instance, IOSurface drawables totaled 377 MB of a 1472 MB footprint; dropping the buffer count from 3 to 2 for the layers that were not on screen would cut roughly a third of that class's memory — on the order of 100-120 MB on this instance depending on exactly how many of the 31 were hidden, scaling with the ratio of hidden to visible surfaces.

The same sampling found glyph-atlas-sized textures (1024² grayscale + 256² color; 93 and 94 regions respectively — arithmetically 3 per layer, the same ratio as the drawables — totaling ~119 MB for 26 terminal sessions) sitting alongside the drawables, similarly unreclaimed by occlusion. We want to flag an ownership ambiguity here rather than gloss over it: whether these atlases are truly duplicated per *surface*, or whether they're a per-`App`-owned cache (Ghostty's `font.SharedGridSet`, which by this library's own architecture is owned by `App`) that happens to move 1:1 with our surface count because our own design creates one `ghostty_app_t` per surface — we can't establish which from outside the library, since our measurement can't distinguish the two when app count and surface count move together. Either way, it's evidence that whatever occlusion does today, it isn't releasing this class of GPU-side allocation — only, as best we can tell, gating the render loop. That ambiguity is why atlas sharing itself isn't one of the two asks below; we're not confident enough in the ownership model to ask for a specific fix there.

**Corroborating report from a different libghostty-based multiplexer:** `github.com/manaflow-ai/cmux` issue #1435 reports 67 panes, an 8.4 GB footprint, ~90% GPU memory, with IOSurface 4,994 MB / IOAccelerator 1,341 MB / owned-graphics 1,286 MB — proportionally close to what we measured, and still open. We want to be careful about how much weight this carries: two independent hosts sharing a signature is *consistent* with a defect in the renderer, but it's equally consistent with both hosts independently making the same integration choice (keeping every pane's surface alive and merely occluded rather than destroying and recreating it, which is the path of least resistance through the current API). We can't distinguish those from outside the library. Worth noting too: that report frames its numbers as growth accumulating over the session's uptime, while our own measurement (above) found the footprint flat and non-monotonic over 20 minutes of idle sampling on our instance — so the two reports' diagnoses aren't identical, even though the steady-state proportions are close. What isn't ambiguous, regardless of either question, is the absence of any GPU-release API in the public header — that's a fact about the surface, confirmed above by direct inspection, not an inference from the cmux report.

## Why an embedder can't work around this in its own tree

Nothing an embedder does at the call-site level can reduce a surface's GPU footprint short of `ghostty_surface_free`, for a surface it intends to keep showing the same content. We confirmed this isn't a case of the wrapper failing to expose an available primitive — `setOcclusion` and `free` are both direct 1:1 calls into the C API with no intermediate Swift-side state (above), and the drawable pool itself is never touched by the wrapper (no `nextDrawable`/`maximumDrawableCount`/`IOSurface` usage anywhere in its source). The swap chain and glyph atlases live entirely inside the vendored renderer, reached only through `ghostty_surface_draw`/`ghostty_surface_refresh`, which we don't control the internals of. An embedder can choose *when* to call `set_occlusion` or `free`, but has no way to ask the library to give back memory for a surface it wants to keep alive. (`ghostty_surface_set_size` does shrink the drawable pool — our own resize measurement above shows a clean 1:1 swap to the smaller size — but that isn't a usable workaround for a hidden surface an embedder intends to resume unchanged: it changes the terminal's row/column grid, reflows scrollback to the new width, and SIGWINCHes the child process, all real side effects on state the embedder doesn't want to disturb just to save memory while a surface is off screen.)

We weren't sure whether this belongs here or further upstream, at `ghostty-org/ghostty` itself, since the swap chain lives in the vendored renderer rather than this wrapper's own Swift code. We noticed this repo pins the vendored source at a specific commit (`Ghostty.ref`, currently `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`) and already carries `Patches/ghostty/` — several Metal-renderer patches applied to that source at build time, including `0008-macos-metal-texture-storage.sh` and `0005-ios-metal-rendering.sh`, which patches `src/renderer/metal/IOSurfaceLayer.zig` directly — the same file that owns the swap-chain layer both asks below target. So a change in that area already has precedent landing through this repo's build rather than requiring an upstream ghostty change first. We're filing here on that basis, but happy to refile at `ghostty-org/ghostty` instead if that's a better fit.

## Proposed changes

**Ask 1 — cheap, additive: lower the effective drawable-buffer count for occluded surfaces.**

Shape: when a surface's occlusion flag is set to `true` (i.e., after `ghostty_surface_set_occlusion(surface, true)`), reduce the renderer's swap-chain buffer count from its current default of 3 to 2. Restore the normal count when occlusion is cleared. Occlusion tracking already exists at the surface/renderer level and, as best we can tell from outside the library, currently only gates the render loop — we can't see from here whether extending it to also touch buffer count is a small change or requires new plumbing, only that the occlusion signal it would key off of already exists and no new terminal/PTY-affecting state would be involved. (If the swap chain is a plain `CAMetalLayer`, note that `maximumDrawableCount` only accepts 2 or 3 — there's no "go lower than 2" version of this ask on that path, though the renderer's actual `IOSurfaceLayer` swap chain may not have the same constraint.)

One thing we can't verify and want to flag rather than gloss over: if the buffer pool drains lazily as drawables are recycled through drawing, an *occluded* surface that has stopped drawing might never actually shrink from 3 to 2 in practice — the count would only drop the next time that surface draws, which may not happen while it stays hidden. If that's the case, the useful form of this ask is an active purge at the occlusion transition (drop the now-unneeded buffer immediately, not lazily), rather than just lowering the target count.

**Ask 2 — larger, structural: free the swap chain on occlusion, or add an explicit release/reacquire pair.**

Either:

- Extend `ghostty_surface_set_occlusion(surface, true)` to also free the swap-chain IOSurfaces — and, if it turns out to be surface-owned rather than a shared `App`-level cache (see the ownership caveat above; we're not certain which it is), the glyph-atlas texture memory too — reallocating them lazily on the next `ghostty_surface_draw` after occlusion is cleared — if that's an acceptable change to the existing call's contract; or
- Add an explicit pair, e.g. `ghostty_surface_suspend_gpu(surface)` / a resume that's implicit on the next draw call, that releases GPU-side resources while leaving the surface handle, terminal state, and PTY untouched, for callers that want to keep two concepts (visibility vs. GPU-resource retention) independently controllable.

We think of Ask 1 as the practical near-term win and Ask 2 as the fix the underlying problem actually calls for; we'd be glad to see either land, or land in that order. This one touches the vendored renderer rather than pure Swift, so we're less confident we could put together a correct PR for it ourselves the way we could for the `command`/`wait_after_command` ask — but we'd be glad to help test against a real multi-surface workload, or take a swing at Ask 1 specifically if a maintainer can point us at where occlusion currently gates the render loop.

## What it would let embedders do

Ask 1, if it works as described (see the lazy-drain caveat above), bounds one component of per-surface graphics memory (drawable buffers) by roughly a third for every surface not currently on screen, with no behavior change for visible surfaces; we'd expect no risk to terminal/PTY state, since neither the surface handle nor occlusion's existing render-loop-gating behavior would change. On our measured instance (26 terminal sessions, 31 layers, at least 20 demonstrably not visible), that's on the order of 100-120 MB of a 1472 MB footprint.

Ask 2, done fully, would let an embedder's steady-state graphics footprint scale with the number of *visible* surfaces rather than the number of *open* ones — the actual ceiling for any embedder holding many surfaces open in the background (tabs, panes, or any "keep it warm so it can resume instantly" design). On our measured instance that's the difference between ~42 MB of graphics memory per open terminal session, permanently (~35 MB per rendered layer plus other per-session overhead), versus close to zero for the majority of sessions that were not on screen at sampling time (the window's content-area geometry bounds at least the dominant layer class to at most 2 visible at once, out of 31 layers total).

## Two minor, unrelated observations (low confidence, not part of either ask above)

While tracing this we noticed two small things in the wrapper that seem plausibly unintended, though we're not confident either is significant enough to be its own report:

- **`AppTerminalView` keeps a reference to the `CAMetalLayer` it creates in `commonInit`, even after the renderer can swap it out.** The ivar is declared at `AppTerminalView.swift:15`; the layer is created and installed at `AppTerminalView.swift:59-67`. Per the renderer's own comment at `AppTerminalView+Lifecycle.swift:174-182`, `self.layer` can be swapped to an `IOSurfaceLayer` once IOSurface-backed compositing kicks in — but the cached ivar keeps the original `CAMetalLayer` alive with a live `MTLDevice`, and `updateMetalLayerMetrics` (`AppTerminalView+Lifecycle.swift:190-196`) keeps writing `contentsScale`/`drawableSize` to it every layout pass, "in case anything else still reads through it." A bare `CAMetalLayer` doesn't allocate drawables until `nextDrawable()` is called on it (and nothing in the wrapper calls that), so we don't think this costs meaningful memory — but it does look like dead weight that could be dropped once the swap to `IOSurfaceLayer` happens.
- **`synchronizeMetrics` calls `ghostty_surface_set_size` unconditionally, ahead of its own change-detection guard.** `TerminalSurfaceCoordinator.swift:185` calls `surface.setSize(...)` (which wraps `ghostty_surface_set_size`) before the metrics-equality check at `:196` that would otherwise skip an unchanged size. Both `layout()` and `setFrameSize(_:)` in `AppTerminalView+Lifecycle.swift:148-158` call `synchronizeMetrics` (via `fitToSize()`) on every AppKit layout pass, so this fires more often than a size actually changes. Harmless if the renderer short-circuits an unchanged size internally; we can't tell from the Swift side whether it does.

Neither of these is something we're confident is worth your time on its own — just flagging them in case they're useful data points alongside the two asks above.

Thank you for maintaining this library and the wrapper around it — we recognize both asks touch the renderer's internals, and we appreciate you taking the time to consider them.
