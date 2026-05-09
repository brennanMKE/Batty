# Building a SwiftUI Multi-Terminal Mac App on libghostty

A getting-started guide for embedding Ghostty's terminal core in a native macOS app that supports multiple terminal sessions in a single window — with notes on adding remote access later.

> **Working name:** Batty (a colony of terminals, navigated by echo)

---

## 1. What you're building on

Ghostty's core is split into two pieces:

- **Ghostty** — the standalone, full-featured terminal emulator app you already know.
- **libghostty** — the C-compatible library extracted from Ghostty's core. The Ghostty macOS app is itself just a Swift/AppKit/SwiftUI consumer of libghostty. That same library is what you'll embed.

There's also **libghostty-vt**, a smaller zero-dependency subset that handles only VT sequence parsing and terminal state. It's the right choice if you want to render the terminal yourself or run it in non-GUI contexts (WASM, server-side log rendering, etc.). For a full-featured terminal app, you want the full libghostty, not just `-vt`.

**Important caveat:** as of this writing, libghostty has *not* been tagged with a stable version. The Ghostty team has explicitly said the C API signatures are still in flux even though the underlying functionality is rock-solid (it powers Ghostty itself). Plan for some churn.

---

## 2. Reference projects — read these first

Before writing any code, study these. They're all doing some flavor of what you want:

| Project | What it is | Why look |
|---|---|---|
| [muxy-app/muxy](https://github.com/muxy-app/muxy) | macOS terminal multiplexer in SwiftUI + libghostty | **Closest match to what you want.** Vertical tabs, horizontal/vertical splits, workspace persistence, themes. Look at `GhosttyKit/`, `Muxy/`, and `Package.swift`. Has a companion iOS app for remote terminal access — directly relevant to your echolocation feature. |
| [ghostty-org/ghostling](https://github.com/ghostty-org/ghostling) | Minimum-viable terminal emulator on the libghostty C API | Single-file C example showing the smallest end-to-end integration. Uses Raylib instead of Metal so the rendering parts won't transfer, but the lifecycle and IO patterns will. |
| [ghostty-org/ghostty (macOS app)](https://github.com/ghostty-org/ghostty) | Ghostty itself — Swift/AppKit/SwiftUI, links libghostty | The canonical example of how to wire libghostty into a Mac app. Look at the `macos/` directory in the repo. |
| [Uzaaft/awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty) | Curated list of libghostty consumers | Useful for seeing how many people are doing this, what problems they hit, and how they solved them. |
| [libghostty-spm](https://github.com/Uzaaft/awesome-libghostty) (linked from awesome list) | Prebuilt `GhosttyKit.xcframework` packaged as a Swift Package | Skip the Zig build pipeline entirely if you're OK with a prebuilt binary. Fastest path to "hello terminal." |
| [Kytos blog post](https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/) | Build log for a Tahoe-targeted libghostty terminal | Best public write-up of the *gotchas* — Metal layer sizing, IME, tab restoration, terminfo bundling. Read this before you start. |
| [Mitchell Hashimoto: Integrating Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui) | The original blog post on the Zig→C→Swift bridge pattern | Authoritative explanation of the build pipeline (libtool → lipo → xcframework → modulemap). Older but the architecture hasn't changed. |

If you remember just one: **clone Muxy and read its source**. It's MIT-licensed and is essentially a working version of the app you described.

---

## 3. The architecture, end to end

```
┌──────────────────────────────────────────────────────────────────────┐
│  Your SwiftUI App (Batty.app)                                        │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐     │
│  │  SwiftUI Views                                              │     │
│  │  • WindowGroup — one window with split/tab layout           │     │
│  │  • SplitView tree (binary tree of panes)                    │     │
│  │  • TabBar (sidebar or top)                                  │     │
│  │  • TerminalSurfaceView : NSViewRepresentable                │     │
│  └─────────────────────────────────────────────────────────────┘     │
│                            │                                         │
│  ┌─────────────────────────▼───────────────────────────────────┐     │
│  │  AppKit Bridge (TerminalSurface : NSView)                   │     │
│  │  • Owns CAMetalLayer                                        │     │
│  │  • Forwards keyDown/mouseDown/scrollWheel to libghostty     │     │
│  │  • Implements NSTextInputClient (for IME, dead keys, CJK)   │     │
│  └─────────────────────────────────────────────────────────────┘     │
│                            │                                         │
│  ┌─────────────────────────▼───────────────────────────────────┐     │
│  │  GhosttyKit (C API via xcframework)                         │     │
│  │  • ghostty_app_new / ghostty_surface_new                    │     │
│  │  • One surface == one terminal session                      │     │
│  │  • libghostty owns: PTY, IO thread, render thread, Metal    │     │
│  └─────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────┘
```

A "surface" in libghostty is a single interactive terminal. Your job in the SwiftUI layer is to manage *N* surfaces and arrange them visually — libghostty handles all the actual terminal stuff (PTY, escape sequences, rendering, fonts).

This is the key insight: **the multiplexing is all yours**. libghostty doesn't know or care that you have multiple surfaces in one window. It just gives you the building blocks.

---

## 4. Setting up the project

You have three integration paths, in order of effort:

### Path A — Use libghostty-spm (easiest)

Add the SPM package to your Xcode project. You get a prebuilt `GhosttyKit.xcframework` and skip the entire Zig build pipeline. Trade-off: you're on whatever version the package maintainer publishes, and you can't easily patch libghostty.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<libghostty-spm-fork>", branch: "main"),
],
```

### Path B — Build libghostty from source (most control)

This is what Ghostty itself, Kytos, and Muxy do.

```bash
# 1. Clone Ghostty
git clone https://github.com/ghostty-org/ghostty.git
cd ghostty

# 2. Build the xcframework (universal arm64 + x86_64)
zig build -Doptimize=ReleaseFast
# Produces: macos/GhosttyKit.xcframework
```

Then in your app's Xcode project:
1. Drag `GhosttyKit.xcframework` into the **Frameworks, Libraries, and Embedded Content** section.
2. Set embedding to **Do Not Embed** (it's a static library).
3. Add linker flags: `-framework Carbon -framework Metal -framework MetalKit` (Carbon is needed for HID event constants).
4. Copy Ghostty's resource tree into your app bundle:
   - `YourApp.app/Contents/Resources/terminfo/78/xterm-ghostty` (sentinel file libghostty looks for)
   - `YourApp.app/Contents/Resources/ghostty/shell-integration/...`

The resource bundle is non-obvious and tripped up Kytos. Without it, shell integration silently doesn't work.

### Path C — Fork Muxy

If you want to skip all of step 4 and just rename what's already working, fork Muxy and start hacking. License is MIT. You'll inherit a working build pipeline, a SwiftUI tab+split UI, theme support, and workspace persistence. Drawback: you'll spend time understanding someone else's code organization before you can productively change things.

> **Recommendation for getting started fast:** Path A or C. Move to Path B once you need to patch libghostty itself or pin to a specific commit.

---

## 5. The C ↔ Swift bridge

Once `GhosttyKit.xcframework` is linked, Swift can `import GhosttyKit` and call the C API directly:

```swift
import SwiftUI
import GhosttyKit

@main
struct BattyApp: App {
    @State private var ghosttyApp: ghostty_app_t?

    init() {
        // Initialize the global Ghostty app
        var config = ghostty_config_new()
        // ...load config...
        ghosttyApp = ghostty_app_new(/* ... */)
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(app: ghosttyApp)
        }
    }
}
```

A few things from your prior experience that apply directly here:

- **You've already done Swift 6 + C interop** with `std::function` and Sendable concerns — most of the same patterns apply. C function pointers don't capture context, so you'll use the standard `Unmanaged<T>.passUnretained(self).toOpaque()` trick to round-trip Swift objects through `void*` userdata.
- **C strings**: libghostty returns `const char*` in many places. Wrap with `String(cString:)` carefully and watch for ownership — some are owned by libghostty and must not be freed by you.
- **Threading**: libghostty spawns its own IO and render threads per surface. Anything Swift does to surface state needs to be Sendable-aware. The `@MainActor` boundary matters.

---

## 6. Surface lifecycle in SwiftUI

The single trickiest piece is bridging libghostty's `NSView`-based surface into SwiftUI's declarative tree. The skeleton:

```swift
struct TerminalSurfaceView: NSViewRepresentable {
    let surfaceConfig: SurfaceConfig

    func makeNSView(context: Context) -> TerminalSurfaceNSView {
        let view = TerminalSurfaceNSView()
        view.createGhosttySurface(config: surfaceConfig)
        return view
    }

    func updateNSView(_ nsView: TerminalSurfaceNSView, context: Context) {
        // Push config changes down
    }

    static func dismantleNSView(_ nsView: TerminalSurfaceNSView, coordinator: ()) {
        nsView.destroyGhosttySurface()
    }
}

final class TerminalSurfaceNSView: NSView, NSTextInputClient {
    private var surface: ghostty_surface_t?
    private let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
    }

    // Forward to libghostty
    override func keyDown(with event: NSEvent) { /* ghostty_surface_key */ }
    override func mouseDown(with event: NSEvent) { /* ghostty_surface_mouse_button */ }
    override func scrollWheel(with event: NSEvent) { /* ghostty_surface_mouse_scroll */ }

    // NSTextInputClient — required for IME, dead keys, CJK input
    func insertText(_ string: Any, replacementRange: NSRange) { /* ... */ }
    // ... rest of NSTextInputClient ...
}
```

**Watch out for:**

- **Metal drawableSize.** When SwiftUI resizes the view, you must update `metalLayer.drawableSize` to match `bounds.size * contentsScale`. Get this wrong and you'll see blurry text or clipped rendering. The Kytos write-up calls this out specifically.
- **First-frame flash.** There's a window between `makeNSView` returning and libghostty's first Metal draw where you can show a blank black frame. Set the layer's background color to your terminal's background up front.
- **NSTextInputClient is non-negotiable.** Skip it and you break CJK users, emoji input, and dead keys (e.g. `é` on US-International keyboard). It's a ~15-method protocol but most methods can return defaults.

---

## 7. Multiple terminals in one window — the data model

The split + tab pattern that Muxy and most editors use is a **recursive binary tree**:

```swift
indirect enum SplitNode: Identifiable {
    case leaf(TabArea)                              // a tab strip with N terminals
    case split(direction: SplitDirection,
               ratio: Double,
               left: SplitNode,
               right: SplitNode)

    var id: UUID { /* ... */ }
}

struct TabArea: Identifiable {
    let id: UUID
    var tabs: [TerminalTab]
    var activeTabID: UUID
}

struct TerminalTab: Identifiable {
    let id: UUID
    var title: String
    var surfaceID: UUID  // maps to a libghostty surface
}
```

This gives you arbitrary nesting (split inside split inside split) and is straightforward to render with a recursive SwiftUI view that switches on the case. It also serializes cleanly for workspace persistence.

The mapping `surfaceID → ghostty_surface_t*` lives in a registry/store keyed by UUID. This indirection matters because SwiftUI will recreate views on state changes and you don't want to recreate the underlying surface (which would kill the shell process).

---

## 8. Persistence and window restoration

This is the next gotcha after surface lifecycle. SwiftUI's `WindowGroup(for:)` restores individual windows but does *not* restore tab groupings reliably. Both Muxy and Kytos build their own persistence layer on top:

- Serialize the full split tree + tab list + active selections to `~/Library/Application Support/Batty/workspace.json` on shutdown and at intervals.
- On launch, replay the saved state into new windows.
- For native macOS tab groups (`addTabbedWindow`), you may need a retry loop because the API silently fails if the target window isn't yet visible. Kytos polls every 100ms for up to 4 seconds.

You probably don't need native macOS tab groups for v1 — your own in-window tab strip (like Muxy's vertical sidebar) is simpler and gives you more control.

---

## 9. Adding remote access (the echolocation feature)

A few options, increasingly ambitious:

1. **Just SSH inside the terminal.** Trivial — it's already a terminal. The session is just `ssh user@host`. Adds nothing custom but works on day one.

2. **Saved hosts / connection manager.** A SwiftUI sidebar or palette that launches new tabs preconfigured with `ssh ...` commands. Modest UX improvement.

3. **Mosh integration.** Mosh handles latency and reconnection well — the "echolocation under poor signal" metaphor practically writes itself. Spectty and other libghostty-based mobile terminals already do this.

4. **Custom remote protocol (Muxy's approach).** Muxy has a desktop ↔ iOS companion app over the local network that exposes the desktop's terminals to a phone client. That's full remote access to running sessions, not just an SSH wrapper. Read their `Mobile` settings code for a working example. This maps directly to your "see in the dark, navigate by echo" framing.

5. **Ghostty-web / WASM in a browser.** libghostty-vt compiles to WASM. Several projects (RemoteTTYs, webterm, ghostty-web) expose terminals in a browser via a Go agent. Heavier lift but unlocks "access my Mac's terminals from any device."

For "Batty" specifically, **option 4 is probably the best fit for your concept**. The metaphor lines up — a colony with members away from the roost, communicating by echo — and the work is mostly application-level (network protocol, auth, mobile UI), not terminal-emulation level.

---

## 10. Suggested first milestones

Roughly in order:

1. **Hello, surface.** Get a single libghostty surface rendering in a SwiftUI window using Path A or C. You should see a working shell prompt. Verify font rendering looks right and that you can type.
2. **Two surfaces side by side.** Hardcode a horizontal split with two surfaces. Confirm both have working PTYs and that focus/input goes to the right one.
3. **Tab bar.** Add a tab strip in one pane. Cmd-T creates a new tab; Cmd-W closes one. Cmd-1..9 selects.
4. **Recursive splits.** Replace your hardcoded split with the `SplitNode` tree. Cmd-D / Cmd-Shift-D for vertical/horizontal split.
5. **Persistence.** Save and restore the workspace tree on launch.
6. **Theme support.** Read Ghostty theme files (`.ghostty` config) and apply them to surfaces. Cheap big win — there are 200+ themes already.
7. **Remote access v1.** SSH connection manager + saved hosts.
8. **Remote access v2.** The phone companion app (only if you actually want this — it's a project on its own).

Stop and ship after step 5 if you just want the multi-terminal app. Steps 6+ are polish and differentiation.

---

## 11. Things that will bite you

- **libghostty C API is unstable.** Pin to a specific commit. Plan for breaking changes when you bump.
- **Resource bundle.** terminfo + shell-integration scripts must be in your `.app` or libghostty falls back to degraded behavior. Add a build phase script.
- **Code signing.** Ghostty is notarized; if you distribute Batty outside the App Store, you'll need a Developer ID and to notarize on every release. Sparkle (which Muxy uses) handles auto-updates.
- **Sandboxing.** A terminal needs to run arbitrary processes, which clashes with App Store sandbox rules. Almost all libghostty consumers ship outside the App Store for this reason.
- **Universal binary.** You'll want both arm64 and x86_64 unless you're explicitly Apple-Silicon-only. The Zig build handles this via `lipo`; the SPM prebuilt should already be universal.
- **Metal in SwiftUI previews.** SwiftUI previews don't always cooperate with Metal layers. Expect previews to be limited; rely on actual run + debug.

---

## 12. Useful links

- libghostty Doxygen: https://libghostty.tip.ghostty.org/
- Ghostty repo: https://github.com/ghostty-org/ghostty
- Ghostling (minimal C example): https://github.com/ghostty-org/ghostling
- Muxy (closest reference): https://github.com/muxy-app/muxy
- Awesome libghostty: https://github.com/Uzaaft/awesome-libghostty
- Mitchell on Zig+SwiftUI: https://mitchellh.com/writing/zig-and-swiftui
- Mitchell on libghostty roadmap: https://mitchellh.com/writing/libghostty-is-coming
- Kytos build log (gotchas): https://jwintz.gitlabpages.inria.fr/jwintz/blog/2026-03-14-kytos-terminal-on-ghostty/
- About Ghostty (architecture): https://ghostty.org/docs/about

---

*Last updated: May 2026. libghostty's C API is pre-1.0; expect details here to drift. Cross-reference any specific API call with the current Doxygen docs.*
