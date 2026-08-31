# Batty: Release GPU Resources for Non-Visible Panes

Task spec for Claude Code. Target: the Batty Mac app (SwiftUI/AppKit) embedding libghostty.

## Goal

Hidden panes currently hold their full renderer state. Drive libghostty's occlusion
API from Batty's own session/pane model so that any surface not in the visible layout
releases its Metal swap chain, while its PTY, terminal state, and scrollback stay live.

Do not change PTY lifecycle. Do not free surfaces.

## Background: what is actually allocated

Each libghostty surface holds two independent pools.

**Terminal state (CPU).** Per-surface `PageList` holding screen plus scrollback. Cells
are stored parsed at roughly 12+ bytes each, and the buffer preallocates every cell on
the screen, so pane width drives cost more than printed content. Current default is
`scrollback-limit-bytes = 50_000_000` per surface, with `scrollback-limit-lines` also
available. Not affected by occlusion.

**Renderer state (GPU / unified memory).** Per-surface `SwapChain`. On Metal
`swap_chain_count = 3`, and each `FrameState` holds its own uniforms buffer, cell text
buffer, cell background buffer, grayscale atlas texture, color atlas texture, and render
target. Three copies per pane. This is what occlusion reclaims.

## The API

```c
void ghostty_surface_set_occlusion(ghostty_surface_t, bool visible);
```

Declared in `include/ghostty.h`. Note the parameter is **visible**, not occluded. Passing
`false` means the surface is not visible.

Call path: `ghostty_surface_set_occlusion` -> `Surface.occlusionCallback` -> renderer
thread `.visible` mailbox message -> `Renderer.setVisible(false)` ->
`releaseGpuResources()`, which deinits the whole swap chain. It is rebuilt lazily on the
next `drawFrame`.

Side effects of `visible = false`, all desirable here:

- Render thread QoS drops to `.utility`
- `updateFrame` is skipped entirely; no cell rebuilding
- Cursor blink timer disarms
- Kitty graphics animations pause, and resume when visibility flips back
- Terminal mode 2033 visibility report is emitted if the running program enabled it

For the embedded apprt, `apprt.must_draw_from_app_thread` is false, so
`releaseGpuResources` runs on the render thread automatically. No app-thread coordination
needed. Do not port the GTK pattern of calling release manually.

## The gap being fixed

Upstream's macOS app wires occlusion only at window granularity. See
`macos/Sources/Features/Terminal/BaseTerminalController.swift`:

```swift
private func syncSurfaceTreeOcclusionState() {
    let visible = self.window?.occlusionState.contains(.visible) ?? false
    for view in surfaceTree {
        if let surface = view.surface, view.isWindowVisible != visible {
            ghostty_surface_set_occlusion(surface, visible)
            view.isWindowVisible = visible
        }
    }
}
```

One flag applied to every surface in the window. Hidden tabs and non-visible splits stay
marked visible and keep their swap chains. Batty needs per-pane resolution.

## Required behavior

A surface is visible if and only if **all** of these hold:

1. Its window's `occlusionState` contains `.visible`
2. Its session is the active session in that window
3. Its pane is present in the active session's current layout (not a hidden tab, not
   collapsed, not zoomed out of view)

Anything else is `visible = false`.

## Implementation

### 1. Single source of truth

Add one resolver that computes visibility for a pane from Batty's model. Every path that
can change visibility calls one `syncOcclusion()` that walks all surfaces and applies the
resolver. Do not scatter `set_occlusion` calls at individual event sites.

Triggers that must call `syncOcclusion()`:

- `NSWindow.didChangeOcclusionStateNotification`
- Active session change
- Tab selection change
- Split create, close, resize, zoom, unzoom
- Pane moved between sessions or windows
- Window miniaturize / deminiaturize
- App hide / unhide
- Session restore completion

### 2. Track last-applied state per pane

Keep a `isSurfaceVisible: Bool` on the pane's view model and skip the call when unchanged.
`occlusionCallback` early-returns on no-op, but the mailbox round trip and the mode 2033
check are not free, and these events fire in bursts during resize and drag.

Initialize this to `false`, not `true`, so the first sync after surface creation is always
applied.

### 3. Get the initial state right

This is the highest-value correctness detail. A surface created into a hidden tab, or
restored from a persisted session, must be marked non-visible before or immediately after
creation. Otherwise it allocates a full swap chain it never draws with, and nothing frees
it until the user happens to reveal and re-hide that pane.

Call the resolver as part of surface creation, not only from notification handlers.

### 4. Handle pane moves across windows

When a pane is dragged to another window, its window-level visibility can change without
any notification firing on the destination. Re-run `syncOcclusion()` on both source and
destination windows after the move completes. Upstream tracks `isWindowVisible` on the
view specifically to restore occlusion state after a drag; Batty needs the same but keyed
on the fuller predicate.

### 5. Do not keep layer-backed views for hidden panes

Remove the hosting view from the view hierarchy rather than setting `isHidden = true` or
zero opacity. A retained `CAMetalLayer` and its IOSurfaces are AppKit-side allocations
that libghostty does not own and will not free.

## Explicit non-goals

**Do not free and recreate surfaces.** `termio` and the PTY are owned by `Surface`;
`ghostty_surface_free` takes both down. There is also an open use-after-free on that path:
`SwapChain.deinit` waits only on the frame semaphore, not on the deferred main-queue
present block or the Core Animation transaction flush, so Metal can present a freed
IOSurface after renderer teardown. Filed against iOS, but the code is the shared renderer
teardown path.

**Do not resize hidden panes to shrink buffers.** `ghostty_surface_set_size` would shrink
render targets and cell buffers, but it triggers reflow and destroys the pane's layout and
scrollback wrapping. Not acceptable.

**Do not touch scrollback limits in this change.** Tracked separately below.

## Verification

Build a repro: one window, one session, N panes with only 2 visible. Fill several hidden
panes with heavy scrollback.

Measure **footprint**, not VM size. Scrollback compression uses `MADV_FREE_REUSABLE` on
Darwin, which lowers resident memory while leaving virtual allocations in place, so VM
size will not move.

Expected results:

- Occluding a pane drops footprint by the swap chain cost: 3 frames of (atlas textures +
  cell buffers + render target sized to the pane)
- Revealing an occluded pane rebuilds the swap chain on the next `drawFrame` with no
  visible flash or stale frame
- Terminal content in an occluded pane is current on reveal, meaning the PTY kept reading
- Cursor blink and any Kitty graphics animation resume on reveal

Regression checks: pane drag between windows, session restore at launch, zoom and unzoom,
window miniaturize and restore.

## Follow-up work, separate change

Renderer occlusion does not touch terminal state. If footprint is still high after this
lands, the remaining cost is `PageList`:

- Confirm the pinned libghostty has `scrollback-compression` (default `true`), which
  transparently compresses non-viewport pages for a reported 70 to 90 percent physical
  memory reduction on those pages. Idle scheduler is `Compression` in
  `src/renderer/Thread.zig`, on a 250 ms idle timer after renderer wake.
- Consider a lower `scrollback-limit-lines` for background or archived sessions.
  Prefer the lines limit over the bytes limit; the bytes limit varies unpredictably with
  pane width.
- Pin a recent libghostty. There was a large scrollback leak from non-standard page
  allocation that agent CLIs provoked heavily by emitting multi-codepoint graphemes into
  primary-screen scrollback. Fixed upstream, but older tags are exposed.

## Source references

Verify these against the pinned libghostty revision before relying on line-level detail.

- `include/ghostty.h` - `ghostty_surface_set_occlusion`
- `src/Surface.zig` - `occlusionCallback`
- `src/renderer/Thread.zig` - `.visible` mailbox handling, QoS class selection,
  `updateFrame` and cursor timer skips, `Compression`
- `src/renderer/generic.zig` - `setVisible`, `releaseGpuResources`, `SwapChain`,
  `FrameState`
- `src/renderer/metal/GraphicsAPI.zig` - `swap_chain_count = 3`
- `src/apprt.zig` - `must_draw_from_app_thread`
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` - upstream
  window-granularity implementation to improve on

## Prior art

Both known downstreams implemented per-pane occlusion independently, which is a signal
this is the right shape and that upstream will not do it for you:

- Rootshell (commercial Ghostty-based Mac terminal), build 138: hidden tabs release their
  Metal swap-chain resources and restore on show; restored tabs and tmux control-mode
  panes start with the correct visibility.
- The Windows Ghostty fork lists renderer occlusion for hidden tabs, zoomed-out splits,
  and minimized windows as an added feature.

