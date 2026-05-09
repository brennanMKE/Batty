# Decision: how to unblock the delegate-plumbing-blocked issues

> **TL;DR.** Nine open issues are blocked on the same gap: GhosttyTerminal's SwiftUI-facing `TerminalViewState` only conforms to 4 of the 12 `TerminalSurfaceViewDelegate` sub-protocols, and `sendText(_:)` is `internal`. Two ways forward: open small upstream PRs against `Lakr233/libghostty-spm` (clean, slow, depends on maintainer), or wrap `TerminalView` ourselves with a custom `NSViewRepresentable` (fast, more code, tighter coupling). **Recommendation: open the upstream PRs first; fall back to the wrapper if review stalls.**

---

## What's blocked

Nine v1 issues, all gated on the same upstream gap:

| Issue | Feature | What it needs from GhosttyTerminal |
|---|---|---|
| `#0022` | Drag-and-drop file paths into a surface | Public `sendText(_:)` to inject the shell-quoted path string |
| `#0023` | Drag-over highlight | (depends on #0022 — needs the drag handler we'd register) |
| `#0024` | Bell + OSC 9 capture | `TerminalSurfaceBellDelegate` + `TerminalSurfaceDesktopNotificationDelegate` reachable from SwiftUI |
| `#0025` | `BellFeedStore` | Bell events to populate it |
| `#0026` | Bell Feed popover UI | Events from `#0025` |
| `#0027` | Click-to-jump from feed | Same chain |
| `#0028` | System notifications + visual indicators | OSC 9 desktop-notification delegate |
| `#0035` | Multi-line paste-confirmation sheet | Paste-interceptor delegate **or** public `sendText(_:)` to perform the post-confirm paste |
| `#0036` (close-confirm half) | Don't quit when a process is running | `TerminalSurfaceCommandFinishedDelegate` + OSC 133 command-running signal exposed |

The drag-drop and paste pieces specifically need a way to **send text into a running surface** from our code. The bell / notification / pwd / command-finished pieces need a way to **observe events** that aren't currently published to SwiftUI.

These nine issues represent a meaningful chunk of v1 differentiator (PRD §6.12, §6.13). Without them, Batty is "tabs and splits and themes" — useful but missing the bell-feed and drag-drop features that motivated the project.

---

## What GhosttyTerminal currently exposes

`libghostty-spm` ships four library products. We consume all four via `BattyKit`'s `@_exported import`. The relevant Swift wrapper is `GhosttyTerminal`, which provides:

### `TerminalViewState` (the SwiftUI consumer's entry point)

`TerminalViewState` is the `@Observable @MainActor` class we hold in `TabRuntime.terminal`. It conforms to **four** of the twelve `TerminalSurfaceViewDelegate` sub-protocols:

```swift
// from libghostty-spm: Sources/GhosttyTerminal/State/TerminalViewState+Delegate.swift
extension TerminalViewState:
    TerminalSurfaceTitleDelegate,        // ✓ exposed via .title
    TerminalSurfaceGridResizeDelegate,   // ✓ exposed via .surfaceSize
    TerminalSurfaceFocusDelegate,        // ✓ exposed via .isFocused
    TerminalSurfaceCloseDelegate         // ✓ exposed via .onClose callback
{ ... }
```

The other **eight** sub-protocols exist (`TerminalSurfaceBellDelegate`, `TerminalSurfaceDesktopNotificationDelegate`, `TerminalSurfacePwdDelegate`, `TerminalSurfaceCommandFinishedDelegate`, `TerminalSurfaceProgressReportDelegate`, `TerminalSurfaceOpenURLDelegate`, `TerminalSurfaceHoverLinkDelegate`, `TerminalSurfaceResizeDelegate`) but are not wired into `TerminalViewState`. They're reachable only by setting `terminalView.delegate = …` at the AppKit `TerminalView` level — and `TerminalSurfaceView` (the SwiftUI wrapper we use) doesn't expose that hook.

### `TerminalSurface.sendText(_:)`

`TerminalSurface` is the thin Swift wrapper around `ghostty_surface_t`. It has:

```swift
// from libghostty-spm: Sources/GhosttyTerminal/Surface/TerminalSurface.swift
func sendText(_ text: String) {
    guard let s = surface else { return }
    text.withCString { cStr in
        ghostty_surface_text(s, cStr, UInt(text.utf8.count))
    }
}
```

Note the **lack of `public`** — it's package-internal. `TerminalController` (the orchestration layer above `TerminalSurface`) doesn't expose a `sendText` either; it has `setColorScheme`, `setTheme`, `setTerminalConfiguration`, and `tick`, but nothing to inject text.

So from our side: there is no public way to call `ghostty_surface_text` against a running GhosttyTerminal surface, even though `BattyKit` re-exports `GhosttyKit` (the raw C API). The C function exists, but we can't reach the surface handle.

### `ghostty_surface_t` access

`TerminalSurface.surface: ghostty_surface_t?` is internal. `TerminalController` doesn't expose the surface either. There is no public path from `TerminalViewState` down to a usable `ghostty_surface_t`.

---

## What we need

Four additions to make the blocked group resolvable:

1. **Public `sendText`** somewhere reachable from `TerminalViewState`. Either:
   - `TerminalController.sendText(_: String)` — public method that forwards to the surface.
   - **Or** `TerminalViewState.send(_: String)` — same idea, on the `@Observable` class directly.

2. **`TerminalViewState` conformance to `TerminalSurfaceBellDelegate`** with a published property:
   ```swift
   public internal(set) var bellCount: Int = 0
   public internal(set) var lastBellAt: Date?
   func terminalDidRingBell() {
       bellCount += 1
       lastBellAt = Date()
   }
   ```

3. **`TerminalViewState` conformance to `TerminalSurfaceDesktopNotificationDelegate`** with a published property:
   ```swift
   public internal(set) var lastDesktopNotification: (title: String, body: String, at: Date)?
   func terminalDidRequestDesktopNotification(title: String, body: String) {
       lastDesktopNotification = (title, body, Date())
   }
   ```

4. **`TerminalViewState` conformance to `TerminalSurfacePwdDelegate`**:
   ```swift
   public internal(set) var workingDirectory: String?
   func terminalDidChangeWorkingDirectory(_ path: String) {
       workingDirectory = path
   }
   ```

`TerminalSurfaceCommandFinishedDelegate` and the rest are nice-to-have but not strictly required for v1 — they unblock smaller features (close-confirmation refinement, hover links, etc.).

---

## Path A — Upstream PRs against `Lakr233/libghostty-spm`

### What it looks like

Two small PRs, possibly bundled into one:

**PR 1: Expose `sendText` publicly.**
- Pick a surface for it. Cleanest: add to `TerminalController`:
  ```swift
  // TerminalController.swift
  public func sendText(_ text: String) {
      surface.sendText(text)
  }
  ```
  Or, slightly less invasive, add a forwarder on `TerminalViewState`:
  ```swift
  // TerminalViewState.swift
  public func send(_ text: String) {
      controller.sendText(text)  // requires the controller change too, or reach internally
  }
  ```
- The change is a few lines in `Sources/GhosttyTerminal/Controller/TerminalController.swift` and possibly `Sources/GhosttyTerminal/State/TerminalViewState.swift`.

**PR 2: Make `TerminalViewState` conform to the missing delegate sub-protocols.**
- Mirror the existing pattern in `Sources/GhosttyTerminal/State/TerminalViewState+Delegate.swift`.
- Add three new conformances (`Bell`, `DesktopNotification`, `Pwd`) with corresponding `@Observable internal(set)` properties on `TerminalViewState`.
- ~30 lines of code, all in a single file. No risk to the core terminal emulation.

Both PRs are mechanical: the existing 4-delegate pattern in the source is a clear template for the additional 3+.

### Pros

- **Stays in "use what's available."** Aligns with our explicit policy of not duplicating dependency code.
- **Future GhosttyTerminal updates work for us.** Improvements to surface lifecycle, IME, Metal sizing, etc. flow in via package updates.
- **Other libghostty-spm consumers benefit.** This is a generally useful improvement to the package, not a Batty-specific hack. The maintainer is more likely to merge a generally-useful PR.
- **Low review surface.** Both PRs are tiny and follow the existing pattern.

### Cons

- **Depends on maintainer responsiveness.** Lakr233 actively maintains the package (the README, recent commits, and the explicit "trimmed build" documentation suggest engagement), but we can't force a timeline.
- **We pin a specific commit** to consume the change before a tagged release. Or we wait for a release.
- **If the maintainer disagrees with the API shape**, negotiation could take rounds. But this is a well-trodden path; the existing delegate forwarding pattern is uncontroversial.

### Time estimate

- **Drafting both PRs**: 30–60 minutes if I do it as a subagent task (read the source carefully, write the changes, write commit messages, write PR descriptions explaining why).
- **Submission**: a few minutes.
- **Review-and-merge cycle**: optimistic 1–2 days, pessimistic 1–2 weeks. Could also get bikeshed about the API shape.
- **Pin our `BattyKit/Package.swift` to the new version**: 5 minutes once merged + a release.

### Risk if path A drags

If review takes weeks, all 9 issues stay parked. We can ship a v1 without them — Batty would still have sessions, splits, tabs, themes, multi-window — but we'd be missing the bell-feed and drag-drop features that motivated the project. PRD §11's "libghostty C API instability" risk is essentially this realized at the wrapper level.

---

## Path B — Wrap `TerminalView` ourselves in BattyKit

### What it looks like

Replace our use of `TerminalSurfaceView` with a custom `NSViewRepresentable` wrapping `TerminalView` (the AppKit class) directly. We'd:

1. Build `BattyTerminalSurfaceView: NSViewRepresentable` in BattyKit.
2. Inside `makeNSView`, instantiate `TerminalView` and set `terminalView.delegate = …` to a routing object we control. The routing object conforms to as many `TerminalSurfaceViewDelegate` sub-protocols as we need (probably all of them) and forwards events to our own `@Observable` view-model.
3. Build a `BattyTerminalState: @Observable` class with all the published properties we want (`title`, `bellCount`, `lastDesktopNotification`, `workingDirectory`, etc.). Replace `TerminalViewState` with this in `TabRuntime`.
4. Re-implement the `TerminalSurfaceCoordinator` integration ourselves — display link, metrics, color scheme adoption, theme application. Some of this is doable by reading what `TerminalSurfaceView` does internally.
5. For `sendText`, find a way through `TerminalView` to the underlying `TerminalSurface`. If `terminalView.surface` (an internal property) isn't reachable, fall back to wrapping `TerminalSurface` ourselves — meaning we'd own the entire `ghostty_surface_t` lifecycle, including `ghostty_app_t` creation and tear-down.

### Pros

- **Fast.** No external dependency on a maintainer. We can land it in a session.
- **Full control.** Anything libghostty exposes via its C API is reachable; we can wire whatever delegate combinations we want.
- **Doesn't require a libghostty-spm version bump.** Stays on `1.0.1777879537` (currently pinned via `BattyKit/Package.swift`).

### Cons

- **Substantial code we re-implement.** `TerminalSurfaceView` is ~1000 lines across multiple files (`TerminalSurfaceView.swift`, `TerminalSurfaceCoordinator.swift`, `TerminalViewRepresentable.swift`, `TerminalView.swift`, plus platform-specific extensions). Re-implementing even a subset is real work.
- **Loses GhosttyTerminal upgrades.** Any improvements upstream (Metal sizing, IME polish, display-link tuning) won't flow to us automatically — we'd have to manually port.
- **Risk of subtle bugs.** Metal layer sizing, IME, and display-link timing are exactly the bits the upstream wrapper got right. PRD §11 calls these out as the highest-risk areas.
- **Goes against our explicit policy** ("use what is available as dependencies as much as possible"). The user's directive on 2026-05-08.
- **`ghostty_surface_t` ownership** if we drop down all the way to libghostty C API: we'd need an `ghostty_app_t`, surface configs with Metal callbacks, IO/render thread plumbing, and explicit `ghostty_surface_free` on tear-down — exactly what we avoided by adopting GhosttyTerminal in the first place.

### Time estimate

- **Hello-surface in custom wrapper**: ~half-day if I'm lucky and `TerminalView` has reachable internals; up to a day or two if I have to re-implement the bridge from the ground up.
- **Full delegate routing**: another half-day.
- **`sendText` reachable**: depends. If `terminalView.surface` is internal-but-accessible-via-ObjC-runtime, hours. If not, days.
- **Bug-hunting Metal / IME / display-link issues**: indefinite.

### Risk if path B is the only option

We've effectively abandoned GhosttyTerminal as a SwiftUI integration and reverted to the "Path A" model from `batty-getting-started.md` §4 — the from-scratch approach the original PRD chose. We saved time by adopting GhosttyTerminal for `#0007`/`#0008`/`#0009`; that savings would partially evaporate.

---

## Comparison

| Dimension | Path A (upstream PRs) | Path B (custom wrapper) |
|---|---|---|
| **Time to unblock** | 1–14 days (maintainer-dependent) | 1–4 days (fully under our control) |
| **Code we own** | 0 lines | ~1000+ lines re-implementing the SwiftUI bridge |
| **Risk of regressions** | Low (small, mechanical PR) | Medium-high (Metal / IME / display-link are tricky) |
| **Long-term maintenance** | Negligible (upstream maintains) | Ongoing (we own the wrapper code forever) |
| **Aligns with "use what's available"** | Yes | No |
| **Affects M3/M4 work shipped** | No (additive change to TerminalViewState) | Yes (would replace `TerminalSurfaceView` in `PaneView`) |
| **Future libghostty-spm upgrades** | Flow in automatically | Require manual port |
| **Failure mode** | Maintainer stalls → fall back to Path B | Bugs in Metal/IME → debug ourselves |

---

## Recommendation: Path A first, Path B as fallback

Open the upstream PRs. They're small, mechanical, and follow the maintainer's existing pattern. Lakr233 has been responsive on the package historically (judging by recent commits and the level of documentation in the repo). The upside of merging is real: every consumer of `libghostty-spm` gets the improvements, not just us.

While we wait for review:

- **I keep working on what's not blocked.** `#0030`/`#0031` cadence wiring, `#0019` drag-divider, `#0020` geometric focus.
- **You verify the M3/M4/M8 work** that's already shipped (`#0014`, `#0015`, `#0017`, `#0018`, `#0021`, `#0033`).
- **You set up `batty.sstools.co`** + Sparkle keys when convenient (this is also unblocking, just for `#0038`).

If the PRs stall for >2 weeks, **switch to Path B** with a documented "interim wrapper" issue that we can revert when upstream lands the API. We'd vendor a `BattyTerminalSurfaceView` that exists alongside `TerminalSurfaceView` — easier to remove later than a full replacement.

---

## What I need from you

Decision-wise, just one thing:

**Should I draft the upstream PRs?**

- **Yes** → I'll spawn a subagent in the existing repo (`/Users/brennan/Library/Developer/Xcode/DerivedData/Batty-…/SourcePackages/checkouts/libghostty-spm/`) or fetch a fresh clone, write the changes mirroring the existing 4-delegate pattern, and produce two patch files (or branches) you can push under your GitHub identity. I'd write the PR descriptions explaining the why.
- **Yes, but I want to review first** → I'll write up the proposed code + PR descriptions in a followup markdown file for your eye before anything goes upstream.
- **No, go straight to Path B** → I file an issue capturing the wrapper plan, scope it carefully, and start. We document a follow-up to undo it when upstream catches up.
- **Hold off entirely** → I keep working on the unblocked issues (`#0030`, `#0031`, `#0019`, `#0020`) and revisit this decision later.

I lean toward **"Yes, but I want to review first"** — gives you a final check on the API shape before anything reaches Lakr233's repo, and the doc itself is useful as the basis for the PR description.

---

*Document version: 1 — 2026-05-08. Based on `libghostty-spm 1.0.1777879537` and the source checkout at the time of writing.*
