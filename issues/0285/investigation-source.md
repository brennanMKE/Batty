# #0285 source trace — where the graphics memory is owned

*Read-only source investigation, 2026-07-31. Companion to `memory-report.md`. No code changed.*

## Summary

- **The allocation itself is upstream**, inside the vendored Ghostty Zig renderer shipped as a prebuilt static library (`libghostty.a`). Neither Batty nor the libghostty-spm Swift wrapper allocates a single `IOSurface`, `MTLTexture`, or drawable. The only Metal object either layer creates is one `CAMetalLayer` per view, which Ghostty then *replaces* on the view. Confirmed by symbol presence in the binary: `.SwapChain.deinit`, `.SwapChain.releaseFrame`, `renderer.Metal.initTarget`, `IOSurfaceLayer`, `font.SharedGridSet.ref/deref/collection`.
- **But Batty has two real levers, and one of them is very large.** Batty creates **one `ghostty_app_t` per Tab** (`TabRuntime.swift:99` → `TerminalViewState.swift:76-84` → `TerminalController.swift:155` → `TerminalController+Config.swift:82`). Ghostty's `App` owns the `font.SharedGridSet`, so 111 Terminal Sessions means 111 independent font-grid sets and 111 independent glyph atlases with **zero sharing**. This is the single best explanation for "2,651 IOAccelerator regions averaging 0.53 MB" and for growth during pure scrolling (atlas growth is content-driven, not frame-driven). It originates entirely in Batty code.
- **Occlusion is never signalled — not once, for any surface, ever.** `AppTerminalView.setSurfaceVisible(_:)` (`AppTerminalView.swift:34-36`) is the wrapper's occlusion entry point and it has **zero callers in either repository**. Every one of the 111 surfaces is created with `setOcclusion(true)` (`TerminalSurfaceCoordinator.swift:128`) and stays there for the process lifetime. Background/hidden Tabs keep rendering whenever their PTY produces output. This is 100% Batty-fixable.
- **Teardown is correct.** The close chain does reach `ghostty_surface_free` and `ghostty_app_free`. No retain cycle, no strong self-capture, no cache that outlives a Tab, and no undo/reopen stack. The one wart is that release is *deferred* (dependent on ARC dropping `TabRuntime`), not immediate — see Q1.
- **Verdict on the two sub-claims:** (a) *surfaces retained after teardown* — **not supported by the source**; the free path is intact. (b) *full-size drawables kept alive for occluded/hidden Tabs* — **confirmed as a Batty-side omission**, with an important caveat: occlusion stops the *render loop*, it does not free the swap chain. The C API exposes no "release GPU resources" call short of `ghostty_surface_free` (full symbol list checked). So Batty can stop the growth for hidden Tabs but cannot reclaim their steady-state ~48 MB without killing the PTY. Reclaiming that is an upstream ask.

The cmux corroboration (67 panes, same 5 GB / 1.3 GB split) fits this reading exactly — but note cmux almost certainly makes the same app-per-pane choice, since that is the path of least resistance through this wrapper's API. **The two hosts sharing a signature is not by itself proof the defect is in the renderer; it is equally consistent with both hosts making the same integration mistake.** That distinction matters for where the follow-up gets filed, and it is testable (see Open questions).

## Ownership boundary

| Allocation | Owning code | File:line | Side |
|---|---|---|---|
| IOSurface swap-chain frames (the 5.3 GB / 755 regions) | Ghostty `renderer/metal/SwapChain.zig`, via `ghostty_surface_draw` | `TerminalSurface.swift:132-136` → `libghostty.a` (`.SwapChain.deinit`, `.SwapChain.releaseFrame`) | **upstream** |
| `IOSurfaceLayer` attached to the `NSView` | Ghostty `renderer/metal/IOSurfaceLayer.zig` | referenced at `Patches/ghostty/0005-ios-metal-rendering.sh:26`; symptom documented at `AppTerminalView+Lifecycle.swift:170-178` | **upstream** |
| Glyph atlas textures (the 1.4 GB / 2,651 IOAccelerator regions) | Ghostty `font.SharedGridSet`, owned per `ghostty_app_t` | `libghostty.a` symbols `font.SharedGridSet.{ref,deref,collection}` | **upstream allocation, Batty-controlled multiplicity** |
| **Number of `ghostty_app_t` (and therefore atlases) = number of Tabs** | `TabRuntime.init` | `TabRuntime.swift:99`; `TerminalViewState.swift:76-84`; `TerminalController.swift:142-156`; `TerminalController+Config.swift:68-83` | **Batty** |
| Occlusion state of every surface (permanently `true`) | nobody calls it | `AppTerminalView.swift:34-36` (0 callers); `TerminalSurfaceCoordinator.swift:66,128,212-228` | **Batty** (omission) |
| Orphaned `CAMetalLayer` per view (small) | libghostty-spm | `AppTerminalView.swift:55-63`, kept alive by ivar at `:15`, still fed sizes at `+Lifecycle.swift:188-192` | **upstream (wrapper)** |
| Hidden-Tab `AppTerminalView` retention (view stays in host, `isHidden`) | `TerminalHostStore` | `TerminalHostStore.swift:136, 216-218, 240-242`; `WindowRuntime.swift:419-431` | **Batty** (deliberate, per #0256) |
| Renderer / IO / read threads per surface | Ghostty `renderer.Thread`, `termio.Thread`, `io_exec` read thread | `libghostty.a` symbols `renderer.Thread.*`, `termio.Thread.deinit`, `ThreadPool.*` | **upstream**, count multiplied by Batty's app-per-Tab |
| `ghostty_surface_free` / `ghostty_app_free` invocation | Batty close path → wrapper deinits | `PaneRuntime.swift:80-86` → `TerminalSurfaceCoordinator.swift:262-293` → `TerminalSurface.swift:239-245`; `TerminalController.swift:258-264` | **Batty (correct)** |

## Per-question findings

### 1. Teardown — **not a problem** (with a deferred-release caveat)

The chain is intact end to end:

- `WindowRuntime.closeTab(id:)` (`WindowRuntime.swift:209-229`) → `PaneRuntime.removeTab(id:)` (`PaneRuntime.swift:80-87`), which removes the `TabRuntime` from `tabs` at `:82` **and then** calls `TerminalHostStore.releaseTerminalView(forTabID:)` at `:86`.
- `releaseTerminalView` (`TerminalHostStore.swift:184-191`) drops all four dictionary entries and calls `view.removeFromSuperview()`.
- `removeFromSuperview` fires `viewDidMoveToWindow()` with `window == nil` → `core.stopDisplayLink(); core.setFocus(false)` (`AppTerminalView+Lifecycle.swift:94-97`). **This does not free the surface.**
- The surface is freed when `AppTerminalView` deallocates → its `let core` deallocates → `TerminalSurfaceCoordinator.deinit` (`:262-271`) → `tearDownSurface` (`:273-293`) → `surface?.free()` (`:283`) → `ghostty_surface_free` (`TerminalSurface.swift:239-245`).
- The app is freed when `TabRuntime` deallocates → `TerminalViewState` → `TerminalController.deinit` → `ghostty_app_free` (`TerminalController.swift:258-264`).

Retain-cycle audit, all clean:

- `core.delegate` is `weak` (`TerminalSurfaceCoordinator.swift:19`), pointed at `tab.terminalDelegate`.
- Every platform hook closure captures `[weak self]` (`AppTerminalView.swift:69-94`).
- Ghostty receives the view as `Unmanaged.passUnretained` (`AppTerminalView.swift:85`) and the bridge as `passUnretained` (`TerminalController+Surface.swift:22`) — no C-side ownership.
- `TerminalHostStore.tabRuntimes` is explicitly weak (`TerminalHostStore.swift:64, 261-264`).
- `controller.retainedBridges` is appended on create (`TerminalController+Surface.swift:41`) and removed in `tearDownSurface` (`TerminalSurfaceCoordinator.swift:288`).
- `TerminalViewState.surface` is `weak` (`TerminalViewState.swift:36-38`).
- No reopen/undo/recently-closed stack exists anywhere in `BattyKit/Sources` (grepped).
- `SplitTree.removePane` (`SplitTree.swift:285-294`) genuinely drops the node.

**The caveat.** `releaseTerminalView` does *not* nil `tab.terminalNSView` (`TabRuntime.swift:73`), and does not call `core.freeSurface()` (which exists, `TerminalSurfaceCoordinator.swift:257-260`). So the actual `ghostty_surface_free` is whenever ARC gets around to dropping the last reference to the `TabRuntime` — and SwiftUI holds `TabRuntime` in `TerminalPlaceholderView.tab` (`TerminalPlaceholderView.swift:23`), `PaneView` (`:522`), and `@State private var renamingTab` (`PaneView.swift:19`). In the ordinary case those clear within a render pass or two. But it means teardown is not deterministic, and a stuck SwiftUI reference (e.g. a rename sheet left open on a closed tab) silently keeps a whole ghostty app + surface + PTY + ~48 MB alive with no log line to show for it. `releaseTerminalView` logs "released terminal view" *before* any of that actually happens, so the log in `docs/view-hierarchy.md` §6 is not evidence the surface was freed.

Two paths do not go through `removeTab` at all and rely purely on subtree deallocation: `WindowRuntime.closePane` (`:314-334`) and `WindowRuntime.removeSession` (`:117-137`), plus `RootWindowView.windowWillClose` (`:195-198`). Same conclusion, same caveat.

### 2. Occlusion — **confirmed problem, Batty-side**

- `TerminalSurfaceCoordinator.isDisplayVisible` defaults to `true` (`:66`) and is only mutated by `setDisplayVisible(_:)` (`:212-228`).
- Its only caller is `AppTerminalView.setSurfaceVisible(_:)` (`AppTerminalView.swift:34-36`), which has **zero callers** — grepped both repositories.
- Every surface is therefore created with `setOcclusion(true)` (`TerminalSurfaceCoordinator.swift:128`) and never told otherwise.
- `AppTerminalView` overrides no visibility hook — no `viewDidHide`, no `viewDidUnhide`, no `isHiddenOrHasHiddenAncestor` check, and nothing anywhere observes `NSWindowOcclusionState` (grepped both repos).
- The render gate is `shouldRenderFrame` (`:305-310`): `isDisplayVisible && isAttached()`. `isAttached` is `self?.window != nil` (`AppTerminalView.swift:69`) — **true for hidden views**, because Batty deliberately keeps background Tabs in the host with `isHidden = true` (`TerminalHostStore.swift:136, 216-218, 240-242`) precisely so they never detach.
- So every background Tab renders a full frame each time its PTY wakes it: `bridge.onRenderRequest` → `requestImmediateTick()` (`:76-78`) → `tick()` → `surface.refresh(); surface.draw()` (`:238-241`).
- Hidden panes (#0256) are the same story: `hidePane` sets a `.zero`/invisible placement (`WindowRuntime.swift:426-431`) which only sets `view.isHidden = true`. The surface keeps its **last visible size** — `updatePlacements` only writes `view.frame` when `placement.isVisible` (`TerminalHostStore.swift:209-212`). So a hidden Tab holds a full-size swap chain indefinitely.

One nuance that changes the fix's value: there is **no API to release GPU resources without destroying the surface**. Every `_ghostty_surface_*` export in the vendored binary was dumped; the list contains `set_occlusion` and `free`, and nothing in between. `.SwapChain.deinit` appears only alongside renderer teardown. So calling `setSurfaceVisible(false)` should stop the redraw-driven *growth* for the invisible Terminal Sessions but will not hand back their existing footprint. **Can't tell from source alone** whether Ghostty's occlusion path additionally releases the swap chain — that needs either upstream source or a live measurement.

### 3. Redraw path — **confirmed problem, but not where the report guessed**

Nothing in either Swift layer allocates per frame:

- `tick()` is three C calls and a hook (`TerminalSurfaceCoordinator.swift:231-242`).
- There is no drawable acquisition in Swift at all. `nextDrawable`, `maximumDrawableCount`, `allowsNextDrawableTimeout`, `makeTexture`, and `IOSurface` appear **nowhere** in libghostty-spm's Swift sources (grepped) — the only hits are two comments. The question "does the code use `nextDrawable` correctly" is not answerable at this layer because this layer never touches it; Ghostty's `IOSurfaceLayer` path bypasses `CAMetalLayer` drawables entirely in favour of its own IOSurface swap chain.
- Despite the name, `startDisplayLink()` (`:86-88`) starts no display link. `MSDisplayLink` is imported only for the `DisplayLinkCallbackContext` type; the real mechanism is a one-shot `DispatchQueue.main.async` re-armed per wakeup (`:312-334`). So there is **no per-Tab timer** burning frames on idle Tabs — growth requires actual PTY output. That is consistent with the report's "+277 MB during scrolling, zero lifecycle events".

Read on the +277 MB: with **111 independent `font.SharedGridSet`s**, scrolling novel content grows 111 separate glyph atlases in parallel. Ghostty's atlases grow by doubling and (per the `.ref`/`.deref`/`.collection` symbols) are reference-counted and collected, not shrunk on demand. That produces exactly the observed shape — many mid-size IOAccelerator regions, growth correlated with content rather than frames, never given back. It also predicts the growth should **plateau** once the working glyph set is covered, which a true per-frame leak would not.

Two smaller upstream inefficiencies: `synchronizeMetrics` calls `ghostty_surface_set_size` **unconditionally** (`TerminalSurfaceCoordinator.swift:173`) before its own change-detection guard at `:184`, and both `layout()` and `setFrameSize` call it on every AppKit layout pass (`AppTerminalView+Lifecycle.swift:144-154`). Whether Ghostty short-circuits an unchanged size is not visible from here. Batty does not amplify this — `updatePlacements` writes `view.frame` only on a real change (`TerminalHostStore.swift:210-212`).

### 4. Resize / font change — **can't tell from source alone**

Everything decisive is behind `ghostty_surface_set_size` / `ghostty_surface_update_config`.

What is confirmed clean on this side: the config path frees its predecessor (`TerminalController+Config.swift:40-46` frees the old `ghostty_config_t`, `:44-46` removes the old temp file), and a font-size change goes through `setTerminalConfiguration` → `reconfigure` → `updateConfigSource`, which calls `ghostty_surface_update_config` per retained bridge (`:33-36`) rather than rebuilding surfaces.

But note a **latent surface-rebuild trigger**: `TerminalSurfaceCoordinator.configuration` has a `didSet` that calls `rebuildIfReady()` on any non-equivalent change (`:30-35`), and `rebuildIfReady` tears down and re-creates the surface (`:96-137`). `TerminalSurfaceOptions.isEquivalent` compares `fontSize`, `workingDirectory`, `context`, `backend` (`TerminalSurfaceOptions.swift:28-33`). Batty sets `view.configuration = tab.terminal.configuration` once at creation (`TerminalHostStore.swift:135`) and never again, so this doesn't fire in practice today — but any future code that assigns `configuration` on a live view silently kills and respawns the PTY.

### 5. Glyph atlas — **confirmed problem, and this is the headline**

- Ghostty's atlas cache is `font.SharedGridSet`, present in the binary with `ref` / `deref` / `collection` — i.e. Ghostty *does* implement atlas sharing, and it is keyed and reference-counted.
- In Ghostty's architecture that set is owned by `App`. Batty creates one `App` per Tab, so the sharing mechanism is defeated: 111 Tabs → 111 sets → **no atlas is ever shared between two Terminal Sessions**.
- The chain is unambiguous and all in Batty/wrapper source: `TabRuntime.init` unconditionally constructs a fresh `TerminalViewState` (`TabRuntime.swift:99`), whose `init` unconditionally constructs a fresh `TerminalController` (`TerminalViewState.swift:76-84`), whose `init` unconditionally calls `createApp()` (`TerminalController.swift:155`) → `ghostty_app_new` (`TerminalController+Config.swift:82`). `TerminalController.shared` exists at `TerminalController.swift:46` and Batty never uses it. `TerminalViewState.init(controller:)` — the shared-controller entry point — exists at `TerminalViewState.swift:86-88` and Batty never uses it.

**Honest caveat on the ownership claim:** that `App` owns `SharedGridSet` is Ghostty's documented architecture, and the type is confirmed present in the vendored binary, but the *ownership edge* could not be confirmed from a stripped static library. If the set turned out to be process-global in this Ghostty revision, this finding collapses to "111 apps is wasteful but not the 1.4 GB". Roughly 80% confidence on the per-App reading. Cheap to settle — see Open questions.

**Why Batty can't just fix this alone.** The reason Batty needs a controller per Tab is that per-Tab state is expressed through the *controller's* config: `BATTY_TAB_ID` / `BATTY_PANE_ID` / `BATTY_SESSION_ID` env vars, the `-c` command override, and `wait-after-command` (`TabRuntime.swift:154-200`). Those are controller-wide, so a shared controller would apply one Tab's env to all of them.

The C API already solves this. `ghostty_surface_config_s` carries per-surface `command`, `env_vars` + `env_var_count`, `wait_after_command`, `working_directory`, and `font_size` (`ghostty.h:452-469`). At the pinned version the wrapper doesn't expose them: `TerminalSurfaceOptions` has only `backend`, `fontSize`, `workingDirectory`, `context` (`TerminalSurfaceOptions.swift:10-26`), and `createSurface` never populates the env/command fields (`TerminalController+Surface.swift:16-38`). **That is the precise Batty/upstream seam** — see the addendum below, which resolves it.

### 6. Threads — **upstream-owned, multiplied by Batty**

- Batty creates **no** threads on the terminal path: no `Thread(`, no `DispatchQueue(label:`, no `Task.detached`, no `pthread_create` anywhere in `BattyKit/Sources` or `Batty/` (grepped).
- The wrapper creates none either; its scheduling is a main-queue hop (`TerminalSurfaceCoordinator.swift:322`).
- All threads are Ghostty's: `renderer.Thread.*`, `termio.Thread.deinit`, a separate `io_exec` read thread (binary strings: `io_exec: read thread failed to set flags`, `io_exec: io reader exiting`), a CoreFoundation release thread in the font shaper, and `ThreadPool.*`. That is ~4–5 plus pool workers per surface, matching the observed ~6.
- Because Batty creates one `App` per Tab, any App-scoped or shaper-scoped thread is also per Tab rather than shared — the same amplification as the atlas.
- The ~728 stack regions with no live thread: **can't tell from source alone**. Nothing in Batty or the wrapper detaches a thread. If Ghostty's threads are joined on `ghostty_surface_free`, orphaned stacks would point at surfaces that were never freed — which would contradict Q1 and is worth cross-checking against the live process.

## Orchestrator addendum — the dependency is 12 releases stale, and 1.3.2 unblocks the headline fix

Batty pins libghostty-spm to revision `c69c34354e511af7a3e6d7e5e2a4fa2fed4b90ff` = tag **1.2.2** (`BattyKit/Package.swift:31-34`). Latest upstream is **1.3.2** (`b146b73`, published 2026-07-27), vendoring ghostty commit `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`.

**What the wrapper's own changelog contains, 1.2.2 → 1.3.2** (`git log 1.2.2..1.3.2`): per-surface env vars (#32), prompt navigation (#30), host-managed output queueing (#29), foreground PID / tty (#27), scrollbar action (#37), arm64e slices, a scroll-remainder patch (0010), and one small `Fix AppKit selection copy leak (#23)` — that last one is a C-string leak in `readSelection`, kilobytes, unrelated to the graphics footprint. **No renderer or Metal changes in the Swift layer**, and `Patches/ghostty/0008-macos-metal-texture-storage.sh` is byte-identical across both tags. So the only memory-relevant thing a bump changes is the **vendored ghostty xcframework**, which advanced ~2 months and 8 autopublish rounds.

That window is not empty: ghostty upstream acknowledged leaks in the 1.2.3 era — a PageList leak and a styles leak triggered by TUIs emitting many styles, with Claude Code CLI named as a trigger (ghostty-org/ghostty#10289) — with fixes landing for 1.3. Batty is pinned *behind* those. Unverified whether they touch the graphics half.

**The important find:** 1.3.2 adds exactly the API that follow-up 1 needs.

```swift
// TerminalSurfaceOptions.swift @ 1.3.2
public var envVars: [String: String]   // → ghostty_surface_config_s.env_vars
```

and `createSurface` now populates `surfaceConfig.env_vars` / `env_var_count` (`TerminalController+Surface.swift:34-35` @ 1.3.2). It does **not** add per-surface `command` or `wait_after_command`.

Checked against what Batty actually puts in per-Tab config (`TabRuntime.swift:143-209`):

| Per-Tab config | Actually per-Tab? | Covered by 1.3.2 per-surface API? |
|---|---|---|
| `BATTY_TAB_ID` / `BATTY_PANE_ID` / `BATTY_SESSION_ID` env | yes | **yes** — `envVars` |
| `command` = shell preference | no — global setting, identical for every Tab | n/a |
| `command` = `-c` override + `wait-after-command` (#0282) | yes, but only for `-c` panes | **no** |
| cursor style/blink, font size, keybinds | no — global | n/a |

So after a 1.3.2 bump, the only thing forcing a per-Tab `ghostty_app_t` for an **ordinary** Tab disappears. A viable design: one shared `TerminalController` for all ordinary Tabs, with a dedicated controller retained only for `-c` panes (rare, and few). That collapses ~all glyph atlases to one. Getting `-c` panes onto the shared controller too needs per-surface `command`/`wait_after_command` in the wrapper — a small additive upstream change, since `ghostty_surface_config_s` already carries both fields.

## Proposed follow-ups

Drafted for the orchestrator; not filed from this document.

1. **[Batty] Batty creates one `ghostty_app_t` per Tab, defeating Ghostty's shared glyph-atlas cache.** Fix: route ordinary Tabs through a single shared `TerminalController`, moving per-Tab env into per-surface `envVars` (available after the 1.3.2 bump). Highest expected payoff of anything here. Confidence the diagnosis is right: **high**; confidence it accounts for the full 1.4 GB IOAccelerator figure: **medium-high**. Gated on the live agent's Open question 1.
2. **[Build] Bump libghostty-spm from 1.2.2 to 1.3.2.** Prerequisite for #1 (supplies `TerminalSurfaceOptions.envVars`), and picks up ~2 months of vendored ghostty including the 1.3-era leak fixes. Was previously drafted as an upstream ask; the upstream work is already done, so this is a version bump plus the Batty refactor.
3. **[Batty] Batty never signals occlusion, so background and hidden Tabs render on every PTY wakeup.** Fix: call `AppTerminalView.setSurfaceVisible(_:)` from the same places that set `isHidden` (`TerminalHostStore.swift:216-218, 240-242`) and on `NSWindow` occlusion changes. Cheap, low-risk, directly targets the "+277 MB while scrolling" path for the non-visible Terminal Sessions. Expect it to slow growth, **not** to reclaim existing footprint. Confidence in the omission: **certain**; in the size of the win: **medium**.
4. **[upstream libghostty-spm / ghostty] There is no way to release a surface's GPU resources without destroying the surface and its PTY.** `ghostty_surface_set_occlusion` is the only lever and (apparently) only pauses rendering. An embedder with 100+ mostly-invisible surfaces has no way to bound graphics memory. Ask: free the swap chain on occlusion, or add an explicit release/reacquire API. Most in need of filing upstream, and the one cmux is hitting too. Confidence: **medium** — rests on the swap chain surviving occlusion, which is unverified.
5. **[Batty] `releaseTerminalView(forTabID:)` logs "released" but does not deterministically free the surface.** It leaves `tab.terminalNSView` set (`TabRuntime.swift:73`) and never calls the available `core.freeSurface()` (`TerminalSurfaceCoordinator.swift:257-260`); the actual free waits on ARC dropping `TabRuntime`, which SwiftUI may still hold. Fix: nil the back-reference and free explicitly, and log from the real teardown point. Confidence it is currently leaking: **low**. Confidence it is worth doing: **high**.
6. **[upstream libghostty-spm] `AppTerminalView` orphans the `CAMetalLayer` it creates in `commonInit`.** Ghostty replaces `self.layer` with an `IOSurfaceLayer`, but the ivar at `AppTerminalView.swift:15` keeps the original alive with a live `MTLDevice`, and `updateMetalLayerMetrics` keeps writing `drawableSize` to it (`+Lifecycle.swift:188-192`). Small (a `CAMetalLayer` allocates no drawables until `nextDrawable`), but plainly unintended. Confidence it matters for footprint: **low**.
7. **[upstream libghostty-spm] `synchronizeMetrics` calls `ghostty_surface_set_size` unconditionally on every layout pass**, ahead of its own change guard (`TerminalSurfaceCoordinator.swift:173` vs `:184`). Harmless if Ghostty short-circuits; a per-layout renderer resize if it doesn't. Confidence: **low**, contingent on Q4.

Ordering suggestion: 3 first (cheapest, and the direct answer to the redraw-path observation), then 2 + 1 together (the big one), then 5. Items 4 and 7 go upstream, ideally referencing the cmux report.

## Open questions for live measurement

1. **Settle the atlas question, cheaply.** Open N Tabs and observe whether IOAccelerator region count scales linearly with Tab count from Tab #2 onward. Linear scaling from the very first extra Tab supports per-App atlases; a large fixed cost plus small per-Tab increments refutes it. **This single measurement decides whether follow-up 1 is worth doing.**
2. **Does occlusion free anything?** Call `setSurfaceVisible(false)` on a few Terminal Sessions and watch the IOSurface region count. If it drops, follow-up 3 is a real reclaim and follow-up 4 is unnecessary. If it doesn't, follow-up 4 goes upstream.
3. **Confirm teardown empirically**, since source says it is clean and the report says otherwise. Open 20 Tabs, close them, check both `phys_footprint` **and** the IOSurface *region count*. If regions return to baseline but footprint doesn't, the residue is "owned unmapped (graphics)" accounting, not a leak. If regions stay high, something holds the `TabRuntime` past close.
4. **Is the growth content-driven or frame-driven?** Scroll novel content (`find /`) for 10 min, then a small repeating buffer (`yes`) for 10 min. Atlas growth predicts the first grows and the second plateaus. A per-frame drawable leak predicts both grow equally. Cleanly separates follow-up 1 from follow-up 4.
5. **Thread accounting.** Count threads before and after closing 20 Tabs. If threads drop by ~120 but stack regions don't, that's an upstream stack-reclamation issue; if threads don't drop, it contradicts the source read of Q1.
6. **Per-surface IOSurface count.** 6.8 per Terminal Session is higher than a 3-frame swap chain. Check whether the count per surface is stable or creeps with resize/font events — the latter would revive Q4 as a real finding.
