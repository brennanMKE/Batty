# `TerminalSurfaceOptions` cannot express per-surface `command` / `wait_after_command`, even though the C API already carries both fields

## Problem

`ghostty_surface_config_s` (the C struct passed to `ghostty_surface_new`) already has `command` and `wait_after_command` fields, but the Swift wrapper's `TerminalSurfaceOptions` / `TerminalController.createSurface` never populates them. An embedder that needs a *subset* of its surfaces to launch a specific command (rather than the user's default shell) and control whether the surface stays open after that command exits currently has no way to express that per-surface — the only place `command` / `wait-after-command` can be set today is the app-level `ghostty.conf`-style config text that's loaded once per `ghostty_app_t` via `ghostty_config_load_file` / `ghostty_app_new`. That forces a dedicated `ghostty_app_t` for every surface (or group of surfaces) that needs a distinct command, purely to express two scalar fields the C API already supports per surface.

This report is against tag **1.3.2** (commit `b146b73`, vendoring ghostty `35e1a01`).

## Evidence

**The C struct already carries both fields.** `ghostty.h:479-496`:

```c
typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  ghostty_surface_io_backend_e backend;
  void* receive_userdata;
  ghostty_surface_receive_buffer_cb receive_buffer;
  ghostty_surface_receive_resize_cb receive_resize;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;              // line 490
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;          // line 494
  ghostty_surface_context_e context;
} ghostty_surface_config_s;
```

**The Swift wrapper doesn't expose either field.** `Sources/GhosttyTerminal/Surface/TerminalSurfaceOptions.swift:10-34` (the public struct handed to `createSurface`):

```swift
public struct TerminalSurfaceOptions: Sendable {
    public var backend: TerminalSessionBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    public var envVars: [String: String]
    public var context: TerminalSurfaceContext
    // no `command`, no `waitAfterCommand`
}
```

`envVars` is exactly the field this ask would mirror — it's already exposed and already flows through to `env_vars`/`env_var_count` on the C struct, so the wiring precedent exists in the same file.

**`createSurface` never touches `config.command` or `config.wait_after_command`.** `Sources/GhosttyTerminal/Controller/TerminalController+Surface.swift:15-45`:

```swift
func createSurface(
    bridge: TerminalCallbackBridge,
    configuration: TerminalSurfaceOptions,
    platformSetup: (inout ghostty_surface_config_s) -> Void
) -> ghostty_surface_t? {
    guard let app else { return nil }

    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
    surfaceConfig.context = configuration.context.ghosttyValue
    configureBackend(&surfaceConfig, from: configuration)

    if let fontSize = configuration.fontSize {
        surfaceConfig.font_size = fontSize            // populated
    }

    return withEnvVarEntries(configuration.envVars) { entries, count in
        surfaceConfig.env_vars = entries               // populated
        surfaceConfig.env_var_count = count            // populated
        return finalizeSurface(/* ... */)
    }
}
```

`working_directory` is populated a little further down, in `finalizeSurface` (`TerminalController+Surface.swift:113-114`, via `workingDirectory.withCString { ptr in config.working_directory = ptr ... }`) — the same pattern that would apply to `command`. `command` and `wait_after_command` are set nowhere in this file, and nowhere else in `Sources/GhosttyTerminal` (grepped).

**`isEquivalent(to:)` would also need the new fields.** `TerminalSurfaceOptions.swift:36-42` compares `fontSize`, `workingDirectory`, `envVars`, `context`, and `backend` to decide whether a live surface's config changed enough to warrant a rebuild. `command` / `waitAfterCommand` aren't in that comparison today because they don't exist on the struct; once added, they'd need to join it so callers that rebuild surfaces on config changes see the new fields correctly.

## Why an embedder can't work around this in its own tree

The only channel for `command` / `wait-after-command` today is the app-level config file loaded once per `ghostty_app_t` (`TerminalController+Config.swift:112`, `ghostty_app_new(&runtimeConfig, cfg)`, with `cfg` built from `ghostty_config_load_file` over a rendered `ghostty.conf`-style text file). That config is shared by every surface created against that `App`. If two surfaces need different `command` values, the *only* lever available from the Swift wrapper is to create two separate `ghostty_app_t` instances — even though the C surface-config struct passed to `ghostty_surface_new` already supports the override per surface, and the app-level struct is otherwise irrelevant to the difference.

For an embedder managing many concurrent surfaces (a terminal multiplexer with tabs/panes, for example), that means every surface that needs a distinct launch command forces its own `ghostty_app_t`. Our own instrumentation of a production multiplexer built on this library measured ~3.85 MB of glyph-atlas texture per surface, none of it shared with any other surface — and in our design, each extra `ghostty_app_t` we stand up carries its own set of surfaces, each paying that cost, plus its own renderer/IO threads. (Whether the atlas cache is owned per-`App` or per-`surface` in Ghostty's architecture, we couldn't establish from outside the library — our own measurement is ambiguous on that point, since in our design app count and surface-group count move together. Either way, an embedder forced into extra `ghostty_app_t` instances purely to carry a command override is paying for infrastructure — at minimum separate renderer/IO threads — it wouldn't otherwise need.)

There is no way to express this from outside the wrapper through its intended surface: `TerminalSurfaceOptions` is the only surface-level configuration type exposed to callers, and it doesn't carry the fields. (The one theoretical escape hatch is that `GhosttyKit` re-exports the raw C API, so an embedder could bypass `GhosttyTerminal` entirely and call `ghostty_surface_new` directly with a hand-populated `ghostty_surface_config_s`. That's real, but it means reimplementing the callback bridge, platform setup, display link, and input handling this package exists to provide — not a workaround so much as opting out of the wrapper altogether.)

## Proposed change

Small and additive — the C struct already has the storage, and the `envVars` field is a direct precedent for the wiring shape.

1. **`TerminalSurfaceOptions.swift`** — add two properties alongside `envVars`, both optional like `fontSize` so an unset value leaves whatever `ghostty_surface_config_new()` already established untouched:

   ```swift
   public var command: String?
   public var waitAfterCommand: Bool?
   ```

   Include both in the memberwise `init` (with `nil` defaults so it's source-compatible) and in `isEquivalent(to:)`.

2. **`TerminalController+Surface.swift`** — in `createSurface`, populate the two fields the same way `working_directory` is handled: a `withCString` scope for `command`, since (per this file's own comment at `:31-32`) "the pointers only need to outlive `ghostty_surface_new`, which copies the values during surface init"; `wait_after_command` is a plain bool with no lifetime concerns, written only when set (matching how `font_size` is guarded above it):

   ```swift
   func createSurface(...) -> ghostty_surface_t? {
       ...
       if let fontSize = configuration.fontSize {
           surfaceConfig.font_size = fontSize
       }
       if let waitAfterCommand = configuration.waitAfterCommand {
           surfaceConfig.wait_after_command = waitAfterCommand
       }

       return withEnvVarEntries(configuration.envVars) { entries, count in
           surfaceConfig.env_vars = entries
           surfaceConfig.env_var_count = count
           if let command = configuration.command {
               return command.withCString { cmdPtr in
                   surfaceConfig.command = cmdPtr
                   return finalizeSurface(...)
               }
           }
           return finalizeSurface(...)
       }
   }
   ```

   (The exact nesting can follow whatever shape reads best against the existing `finalizeSurface`/`buildSurface` split — the point is just that `command` needs the same `withCString`-scoped-pointer treatment `working_directory` already gets, and `wait_after_command` is a plain bool passthrough with no lifetime concerns.)

We'd be glad to send a PR for this — it's roughly 20 lines against a clear precedent (`envVars`), and we're happy to match whatever shape or naming you'd prefer over the sketch above.

## What it would let embedders do

Any surface could carry its own launch command and wait-after-exit behavior while still sharing one `ghostty_app_t` — and whatever that App shares across its surfaces (renderer/IO threads at minimum, and possibly the glyph-atlas cache, depending on Ghostty's internal ownership) — with sibling surfaces that don't need a command override. For a multiplexer-style embedder running many concurrent surfaces where only a handful need a command override, this removes the need to stand up a fully separate `ghostty_app_t` solely to express a per-surface command and wait-after-command flag.

Thank you for maintaining this wrapper — the `envVars` addition in a recent release is exactly the shape we're asking for here, just for two more fields the C struct already carries.
