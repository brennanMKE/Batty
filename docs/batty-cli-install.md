# `batty` CLI: build, embed, install, invoke (as-built)

This is a from-the-source record of how the `batty` command-line tool
actually works in this repo today: how it's declared, how it gets into
`Batty.app`, how it lands on the user's `PATH`, and what happens when you
run it. It is written to be self-contained for a reader with no access to
this repo — every path, target name, and code excerpt below was read
directly from the source at the time of writing (2026-07-24) rather than
inferred or assumed.

There is an older document, `docs/cli-tool-install.md`, that is a
**prescriptive design survey** (how the reference project *supacode* does
CLI installation, plus a "replicate this for batty" plan written before
most of this was built). Parts of that plan were superseded during
implementation. See "Where this diverges from `docs/cli-tool-install.md`"
near the end for the specific deltas. Don't use that doc as a source of
truth for current behavior — use this one.

## Orientation

`batty` is a small, standalone command-line executable, built from the
`BattyKit` Swift package and copied into `Contents/Resources/bin/batty`
at app-build time (identically named `batty` inside *either* variant's
bundle, even though the wrapping `.app` itself is not: `Batty.app` for
Prod, `Batty Beta.app` for Beta since `#0279` gave Beta a distinct
`PRODUCT_NAME` so it can sit in `/Applications` next to Prod without a
name collision). The Batty macOS app can install a symlink to it from
Settings → Advanced, after which the command is on the user's normal
shell `PATH` — `/usr/local/bin/batty` for the Prod build,
`/usr/local/bin/batty-beta` for Beta (`#0277`; see "Variant-aware install
path" below), so installing one variant's CLI can never silently repoint
the other's. Today the CLI does exactly one thing:
`batty <path>` (or bare `batty`, which defaults to `.`) resolves the given
directory to an absolute path, builds a `batty://session?path=<path>` URL,
and hands it to `/usr/bin/open`, which launches or activates Batty and
delivers the URL to `NSApplicationDelegate.application(_:open:)`. The app
routes it to a handler that creates a new Session rooted at that directory
in the currently active window. There is no response channel: the CLI
never learns whether the app succeeded, and `open`'s exit code only tells
you whether macOS accepted the URL, not whether Batty acted on it.

## End-to-end trace: `batty ~/some/path`

1. User runs `batty ~/some/path` in a terminal. The shell resolves `batty`
   via `PATH` to `/usr/local/bin/batty`, which is a **symlink** (not a
   copy) to `<Batty.app>/Contents/Resources/bin/batty` — installed by
   `CLIInstaller.install()` (see "Installation to PATH" below).

2. `swift-argument-parser` parses the invocation into `BattyCLI`
   (`BattyKit/Sources/batty/BattyCLI.swift`), a `@main struct BattyCLI:
   ParsableCommand` with a single positional `@Argument var path: String =
   "."`. There are no subcommands today — `batty` is a single-command tool.
   `--version` and `--help` are handled entirely by `swift-argument-parser`
   (no app round-trip); `--version` reports `resolveAppVersion()`'s result
   (see step 3).

3. `BattyCLI.run()` calls `resolvePath(path)`
   (`BattyKit/Sources/batty/SessionCommand.swift`), which forwards to
   `SessionURLBuilder.resolve(path:currentDirectory:)`
   (`BattyKit/Sources/BattyCLICore/SessionURLBuilder.swift`):
   expands `~`, resolves relative paths against the process's current
   working directory, standardizes the result, strips a trailing slash,
   and validates with `FileManager.fileExists(atPath:isDirectory:)` that
   the result exists **and is a directory**. If resolution fails, the CLI
   prints `batty: path does not exist or is not a directory: <input>` to
   stderr and exits with `ExitCode.failure` (status 1) — no URL is built,
   no `open` is spawned.

4. On success, `SessionURLBuilder.buildURL(absolutePath:)` builds a URL via
   `URLComponents` with `scheme = "batty"`, `host = "session"`, and a
   `path` query item holding the absolute, percent-encoded path — e.g.
   `batty://session?path=/Users/jane/some/path`. If component assembly
   somehow fails (not expected for a valid absolute path), the CLI prints
   `batty: failed to build IPC URL for path: <resolved>` and exits 1.

5. `openURL(url)` (`SessionCommand.swift`) spawns `/usr/bin/open -b
   <bundleIdentifier> <url-string>` via `Foundation.Process`, waits for it
   to exit synchronously, and propagates failure: a non-zero `open` exit
   status or a spawn error both produce a stderr message and
   `ExitCode.failure`. `-b <bundleIdentifier>` defaults to
   `ServiceNames.appBundleIdentifier` — the CLI's own compile-time-baked
   variant (`co.sstools.Batty` for Prod, `co.sstools.Batty.beta` for Beta;
   see "Variant-aware install path" below). **`#0279`:** before this, the
   CLI called plain `open <url-string>` with no `-b`, and since both
   variants register the same `batty` scheme (`Configuration/Info.plist`
   is shared), LaunchServices could route `batty <path>` to *either*
   installed variant when both were present — the fix mirrors
   `AppLauncher.launch`'s existing `-b` precedent, which the XPC path
   already used correctly. `open` itself launches the targeted variant if
   it isn't running, or activates it if it is, and delivers the URL through
   the standard macOS Launch-Services/URL-event mechanism — no code in
   Batty has to poll or listen for this beyond registering the URL scheme
   (step 6). This is the full extent of the CLI's own work: it never talks
   to the app directly.

6. On the app side, the `batty` URL scheme is registered via
   `CFBundleURLTypes` in the **literal** `Configuration/Info.plist` (not a
   build setting):
   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLSchemes</key>
           <array>
               <string>batty</string>
           </array>
           <key>CFBundleURLName</key>
           <string>Batty CLI IPC</string>
       </dict>
   </array>
   ```
   macOS delivers the URL to `BattyAppDelegate.application(_:open:)`
   (`Batty/BattyApp.swift`), which filters for `url.scheme == "batty"` and
   calls `BattyURLHandler.handle(url, store: AppStateStore.shared)`.

7. `BattyURLHandler.handle` (`BattyKit/Sources/BattyKit/Runtime/BattyURLHandler.swift`)
   parses the URL back into a path with `SessionURLBuilder.sessionPath(from:)`
   — which validates `scheme == "batty"` and `host == "session"` and
   rejects anything else, so a malformed or foreign `batty://` URL is
   logged and silently ignored rather than trusted — and calls
   `store.addSession(workingDirectory: path)` on the main actor. This
   creates a new `Session` whose first `Pane`/`Tab`'s
   `terminal.configuration.workingDirectory` is the resolved path, lands
   it in the currently active window (not a phantom or a fresh empty
   window — this took two bug-fix rounds, #0251, to get right; see
   "Known limitations / history"), and selects it so the user sees it
   immediately.

8. The terminal surface spawns with its shell's working directory set to
   the requested path (via the existing `TerminalConfiguration.workingDirectory`
   → `TerminalController.finalizeSurface` → `ghostty_surface_new` path
   that Cmd-T / CWD inheritance also use — no CLI-specific spawn logic).

If Batty is **not running** when `batty <path>` is invoked, `/usr/bin/open`
launches it; `application(_:open:)` still receives the URL as part of the
launch sequence (standard AppKit/Launch Services behavior — Batty adds no
special cold-launch handling), and a session is created at the requested
path. Because `BattyApp`'s `WindowGroup` also opens its own default window
on cold launch, a `batty .` that launches Batty from cold yields **two**
sessions: the default `Session 1` (usually at `$HOME`) plus the requested
path's session — documented as acceptable, not a bug, in #0251.

## Reference

### 1. The executable target

`BattyKit/Package.swift` declares three targets relevant to the CLI:

```swift
.target(
    name: "BattyCLICore",
    swiftSettings: swiftSettings
),
.target(
    name: "BattyKit",
    dependencies: [
        "BattyCLICore",
        .product(name: "GhosttyKit", package: "libghostty-spm"),
        .product(name: "GhosttyTerminal", package: "libghostty-spm"),
        .product(name: "GhosttyTheme", package: "libghostty-spm"),
        .product(name: "SlidingTabs", package: "SlidingTabs"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "Textual", package: "textual"),
    ],
    ...
),
.executableTarget(
    name: "batty",
    dependencies: [
        "BattyCLICore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    swiftSettings: swiftSettings
),
```

and the corresponding product:

```swift
.executable(
    name: "batty",
    targets: ["batty"]
),
```

**Why the `batty` executable target depends on `BattyCLICore` and not
`BattyKit`:** this is the single most important architectural fact about
the CLI, and it was *not* the original design — see #0252. The first
implementation (#0249) had `batty` depend on the full `BattyKit` library,
which transitively links `Sparkle.framework` (plus libghostty, SlidingTabs,
Textual) via `@rpath`. The embedded copy lives at
`Contents/Resources/bin/batty`, two directories below
`Contents/Frameworks/`; the CLI's baked-in rpaths can't reach the bundled
framework there, so the embedded binary crashed at launch with `Library
not loaded: @rpath/Sparkle.framework/...`. It only appeared to work when
run via `swift run batty` from the SwiftPM build directory, whose rpath
happens to resolve Sparkle — so the bug shipped past verification in
#0249. The fix (#0252) split a dependency-free `BattyCLICore` target
(Foundation only, no product dependencies) out of `BattyKit`, moved
`SessionURLBuilder` into it, made `BattyKit` depend on `BattyCLICore` and
re-export it (`BattyKit/Sources/BattyKit/BattyCLICoreReexport.swift`:
`@_exported import BattyCLICore`, so existing `import BattyKit` call sites
were unaffected), and pointed `batty` at `BattyCLICore` only. Effect:
binary size dropped from 26 MB to 2.4 MB and `otool -L` shows zero
`@rpath` dependencies. The project's own comment in `Package.swift` states
this plainly:

```swift
// Dependency-free core shared by the GUI app and the `batty` CLI.
// Keeping it free of Sparkle/libghostty/etc. lets the CLI link only
// this — otherwise the CLI transitively drags in Sparkle and crashes
// at launch from the app bundle (no rpath to Contents/Frameworks).
```

So `BattyCLICore` exists specifically **to be shared between the CLI and
the app** while excluding everything GUI/updater-related — confirmed by
reading both the target dependency graph and `BattyURLHandler.swift`,
which does `import BattyCLICore` directly (not just transitively through
`BattyKit`) to use `SessionURLBuilder.sessionPath(from:)`.

**`swift-argument-parser`** (`https://github.com/apple/swift-argument-parser`,
`from: "1.5.0"`) is a package dependency of the `batty` executable target
only — deliberately **not** wired as an Xcode
`XCSwiftPackageProductDependency` on the app target, because doing so
previously broke the unit-test gate (see "Gotcha: the executable-product
Xcode-dependency trap" below).

Source layout:

```
BattyKit/Sources/batty/
├── BattyCLI.swift          # @main entry point, argument parsing
└── SessionCommand.swift    # path resolution, version resolution, URL dispatch

BattyKit/Sources/BattyCLICore/
└── SessionURLBuilder.swift # batty:// URL build/parse/path-resolve, shared by CLI + app + tests
```

There is no `main.swift` in the `batty` target. An earlier version used
top-level code in `main.swift`, but `@main` conflicts with SwiftPM's
implicit top-level-code entry point for a file literally named
`main.swift`, so it was renamed to `BattyCLI.swift` when subcommand
parsing was introduced (#0250).

### 2. The CLI's actual current behavior

Full listing of `BattyKit/Sources/batty/BattyCLI.swift`:

```swift
import ArgumentParser
import BattyCLICore
import Foundation

@main
struct BattyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batty",
        abstract: "Control Batty from the command line.",
        version: resolveAppVersion()
    )

    @Argument(help: "Directory for the new session. Defaults to the current directory.")
    var path: String = "."

    nonisolated func run() throws {
        let resolved = try resolvePath(path)
        guard let url = SessionURLBuilder.buildURL(absolutePath: resolved) else {
            fputs("batty: failed to build IPC URL for path: \(resolved)\n", stderr)
            throw ExitCode.failure
        }
        try openURL(url)
    }
}
```

Key points, verified against this source:

- **No subcommands.** `batty` is a flat, single-argument command. There is
  no `batty session ...` / `batty pane ...` verb grammar today — that is a
  *design proposal* in `docs/batty-cli-design.md` and a *pinned plan, not
  yet built* in issue `issues/0257.md` (status `open` at time of writing).
  Do not assume any verb beyond the bare positional path exists.
- **Bare `batty` (no arguments) defaults to `batty .`** — creates a
  session at the current working directory rather than printing usage.
  This was a deliberate, reviewer-flagged-for-user-sign-off choice (#0250).
- **`--version`** is handled by `swift-argument-parser`'s built-in
  version flag, sourced from `resolveAppVersion()`. **`--help`** is
  `swift-argument-parser`'s automatic help generation from the
  `CommandConfiguration`/`@Argument` metadata — nothing custom.
- **Exit codes:** `0` on success; `1` (`ExitCode.failure`) when the path
  doesn't resolve to an existing directory, when URL assembly fails
  (not expected in practice), when `/usr/bin/open` itself fails to spawn,
  or when `open` exits non-zero. There is no exit code that reflects
  whether the *app* actually created the session — see "Known
  limitations."

`resolveAppVersion()` and the path/URL helpers, from
`BattyKit/Sources/batty/SessionCommand.swift`:

```swift
nonisolated func resolveAppVersion() -> String {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        return "unknown"
    }
    let infoPlist = executable
        .deletingLastPathComponent()  // bin/
        .deletingLastPathComponent()  // Resources/
        .deletingLastPathComponent()  // Contents/
        .appending(path: "Info.plist", directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: infoPlist),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let info = plist as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String
    else {
        return "unknown"
    }
    return version
}
```

This walks up from the **symlink-resolved** executable path
(`/usr/local/bin/batty` → `.../Batty.app/Contents/Resources/bin/batty`)
three directories to `Contents/Info.plist` and reads
`CFBundleShortVersionString`, so `batty --version` always reports the
version of the app it's actually embedded in — no build-time stamping, no
drift between CLI and app version. When run outside any app bundle (e.g.
straight from the SwiftPM build directory via `swift run batty`), this
falls back to the string `"unknown"`.

`resolvePath` and `openURL`:

```swift
nonisolated func resolvePath(_ input: String) throws -> String {
    guard let resolved = SessionURLBuilder.resolve(path: input) else {
        fputs("batty: path does not exist or is not a directory: \(input)\n", stderr)
        throw ExitCode.failure
    }
    return resolved
}

nonisolated func openURL(_ url: URL, bundleIdentifier: String = ServiceNames.appBundleIdentifier) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = ["-b", bundleIdentifier, url.absoluteString]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("batty: failed to open URL: \(error.localizedDescription)\n", stderr)
        throw ExitCode.failure
    }
    guard process.terminationStatus == 0 else {
        fputs("batty: open exited with status \(process.terminationStatus)\n", stderr)
        throw ExitCode.failure
    }
}
```

(`#0279` added the `-b bundleIdentifier` targeting — see step 5 above.)

`SessionURLBuilder` (`BattyKit/Sources/BattyCLICore/SessionURLBuilder.swift`),
in full:

```swift
public struct SessionURLBuilder {
    public nonisolated static func resolve(
        path input: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        let expanded = (input as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(filePath: expanded)
        } else {
            url = URL(filePath: currentDirectory).appending(path: expanded)
        }
        var standardized = url.standardizedFileURL.path(percentEncoded: false)
        if standardized.hasSuffix("/"), standardized != "/" {
            standardized = String(standardized.dropLast())
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return standardized
    }

    public nonisolated static func buildURL(absolutePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "batty"
        components.host = "session"
        components.queryItems = [URLQueryItem(name: "path", value: absolutePath)]
        return components.url
    }

    public nonisolated static func sessionPath(from url: URL) -> String? {
        guard url.scheme == "batty", url.host() == "session" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
              let path = pathItem.value,
              !path.isEmpty
        else { return nil }
        return path
    }
}
```

This one struct is the entire wire format between the CLI process and the
app process: build on the CLI side, parse on the app side, both linking
the identical code from `BattyCLICore` — there is no separately maintained
schema on either end.

### 3. The app side of the channel

- **Scheme registration:** `Configuration/Info.plist` (the literal plist
  file referenced by `INFOPLIST_FILE = Configuration/Info.plist` in
  `Configuration/App.xcconfig`), `CFBundleURLTypes` → `CFBundleURLSchemes`
  → `batty` (shown in full above, step 6 of the trace). This is a static
  Info.plist entry, not synthesized from `INFOPLIST_KEY_*` build settings
  — confirmed by grepping the whole `Batty.xcodeproj/project.pbxproj` for
  `URLTypes`/`URLSchemes`/`INFOPLIST_KEY_CFBundleURL*` and finding no
  matches there. **Both variants register the same `batty` scheme** —
  `Beta.xcconfig` does not override `INFOPLIST_FILE`, so a Beta build
  installed in `/Applications` becomes a *second* LaunchServices handler
  for it (`#0279` leak 3). `#0279` deliberately did not split this into a
  per-variant scheme (e.g. `batty-beta://`): the CLI is the only in-repo
  producer of `batty://` URLs, and targeting it with `-b
  <bundleIdentifier>` (see step 5 above) closes the actual reported defect
  — `batty <path>` landing in the wrong variant. A `batty://` link opened
  from outside the CLI (a browser, a doc) with both variants installed
  still resolves to whichever handler LaunchServices prefers; that residual
  ambiguity was judged out of scope for a testing-only Beta build and
  would require its own Info.plist-per-variant plumbing (none exists
  today) to close properly.
- **Routing:** `BattyAppDelegate.application(_:open:)`
  (`Batty/BattyApp.swift`) — filters incoming URLs to `scheme == "batty"`
  and forwards each to `BattyURLHandler.handle(url:store:)`.
- **Handling:** `BattyURLHandler.handle` (`BattyKit/Sources/BattyKit/Runtime/BattyURLHandler.swift`,
  `@MainActor`) parses with `SessionURLBuilder.sessionPath(from:)` and
  calls `AppStateStore.addSession(workingDirectory:)`. Unrecognized URLs
  (wrong scheme, wrong host, missing/empty `path` query item) are logged
  at `.info` and dropped — never trusted or partially acted on.
- **SwiftUI double-open suppression:** `BattyApp.swift`'s content
  `WindowGroup` and the `Window("Batty Help", id: "help")` scene both
  carry `.handlesExternalEvents(matching: Set())`. Without this, SwiftUI's
  scene machinery independently volunteers to open a *new* window for any
  OS-delivered external URL event, on top of `application(_:open:)`
  correctly adding the session to the active window — producing a stray
  empty window (and, once the `WindowGroup` was fixed, the *Help* window
  became the next fallback target, which is why both scenes needed the
  empty-match-set). This is `#0251` round 2; the code comment in
  `BattyApp.swift` documents it in place.
- **Not running case:** no special-cased cold-launch code exists for
  `batty://`. `/usr/bin/open` launches the app via normal Launch Services;
  AppKit delivers the pending URL through the same
  `application(_:open:)` callback as part of the launch sequence. Because
  `AppStateStore.init` always seeds an initial window with an initial
  session, and `WindowGroup`'s `defaultValue` reuses that same seeded
  `WindowID` (`AppStateStore.shared.initialWindowID`), the URL-added
  session lands in the same real window the user sees, not a phantom
  second runtime — this alignment was the round-1 fix in `#0251`.

### 4. How the binary gets into the app bundle

There is exactly one native app target in `Batty.xcodeproj/project.pbxproj`,
named `Batty` (product `Batty.app`), built under two **schemes** — `Batty
(Prod)` and `Batty (Beta)` — which both build the *same* target/build
phases and differ only via an xcconfig switch (`scripts/set-environment.sh
<Beta|Prod>` writes `Configuration/Active.xcconfig` as a scheme pre-action,
selecting `Beta.xcconfig` — which overrides `PRODUCT_BUNDLE_IDENTIFIER` to
`co.sstools.Batty.beta` and blanks the Sparkle feed URL/key — or
`Prod.xcconfig`, which is empty and just defers to the defaults in
`App.xcconfig`). Neither scheme nor Beta/Prod changes anything about how
the CLI is built or embedded; that only varies by **build configuration**
(Debug vs Release), because the embed script keys off `${CONFIGURATION}`.

The `Batty` target's build phases, in order (from `project.pbxproj`):
`Sources` → `Frameworks` → `Resources` → `Bundle Ghostty Resources` (Run
Script) → **`Embed CLI`** (Run Script) → `Embed Broker` (Run Script, last;
added by `#0270`, embeds the `BattyBroker` launch agent into the same
shared `bin/` directory — see that issue and `docs/xpc/` for the broker
side of this).

The `Embed CLI` phase (`project.pbxproj`, phase id
`26B100020000000000000002`), verbatim as of `#0276`:

```bash
set -euo pipefail
config="$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')"
archflags=()
for a in ${ARCHS}; do archflags+=(--arch "$a"); done
cd "${SRCROOT}/BattyKit"
xcrun swift build --product batty -c "${config}" "${archflags[@]}"
built="$(xcrun swift build --product batty -c "${config}" "${archflags[@]}" --show-bin-path)/batty"
dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
mkdir -p "${dest}"
rm -f "${dest}/batty"
/bin/cp -f "${built}" "${dest}/batty"
```

The phase sets `alwaysOutOfDate = 1`, so Xcode runs it on every build
regardless of `inputPaths`/`outputPaths` — it declares no `inputPaths` at
all. Its declared output path,
`$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/batty`, i.e.
`Batty.app/Contents/Resources/bin/batty`, exists only for Xcode's build
graph (e.g. ordering relative to other phases that touch the same
directory) — this is a plain `cp`, run as an inline shell script build
phase on the app target; the CLI is **not** wired in as an Xcode
package-product dependency (see the Gotcha below for why not).
`CONFIGURATION` is `debug` or `release` (lowercased for `swift build -c`);
`ARCHS` becomes one or more `--arch` flags, which SwiftPM resolves to a
single universal binary at one `--show-bin-path` when multiple arches are
requested. Confirmed by inspecting a real Debug build product
(`~/Library/Developer/Xcode/DerivedData/Batty-*/Build/Products/Debug/Batty.app/Contents/Resources/bin/batty`):
present, `2,553,104` bytes, `file` reports `Mach-O 64-bit executable
arm64`.

**`#0276`: from empty `inputPaths` to `alwaysOutOfDate`, and the narrowed
`rm -f`.** Before `#0276`, this phase declared an `outputPaths` entry but
an *empty* `inputPaths` — worse than declaring neither, because a script
phase with a declared output and no declared inputs is skipped by Xcode's
incremental build once that output file exists. The embedded `bin/batty`
went silently stale after the first build no matter how much CLI source
changed; reproduced directly during `#0276` (change a `batty`-target
source file, rebuild without cleaning, observe the embedded binary keeps
the old `--help` text).

The first attempt at a fix declared real `inputPaths`
(`BattyKit/Sources/batty`, `BattyCLICore`, `BattyXPCCore`) — mirroring
`Embed Broker`'s existing `inputPaths`, which looked like established
precedent. **That attempt didn't work and was reverted in round 2 of
review.** A directory listed in `inputPaths` is stat'd as a directory:
llbuild compares the directory's own mtime against the phase's declared
outputs and does not walk the tree. On APFS a directory's mtime changes
only when its entry list changes (a file created, deleted, or renamed
inside it) — not when an existing file is edited in place. An in-place
rewrite of a source file (same inode, parent directory mtime unchanged)
left the phase skipped and the embedded binary stale even with the
`inputPaths` in place; only an atomic-save editor (which replaces the file
and does change the directory's entry list) had made the first attempt's
test pass. The same mechanism meant a `Package.swift`/`Package.resolved`
change, a bumped dependency pin, or a toolchain change would also have
gone undetected, regardless of how complete the `inputPaths` list was.

The actual fix is `alwaysOutOfDate = 1` (matching the pre-existing
`Bundle Ghostty Resources` phase in the same target, which already uses
it): the phase's real work, `xcrun swift build`, is itself a complete
incremental build system that owns the true dependency graph (sources,
`Package.resolved`, toolchain); mirroring that graph into Xcode
`inputPaths` is duplicated work that two independent scenarios (in-place
edits, package-manifest/toolchain changes) proved incomplete. A no-op
`swift build --product batty -c debug --arch arm64` measures roughly
0.6s, so running the phase unconditionally is cheap. **`Embed Broker` has
the identical `inputPaths`-based construction and the identical latent
gap** — it also now sets `alwaysOutOfDate = 1`; its pre-existing
`inputPaths` are left declared but no longer matter for correctness.
Don't treat either phase's `inputPaths` list as a freshness guarantee.

Separately, the phase used to `rm -rf` the entire shared `dest` directory,
which also deleted `bin/BattyBroker` on every run; it only worked because
`Embed Broker` ran afterward in the target's build-phase list and
re-created its own output every time. `#0276` narrowed this to
`rm -f "${dest}/batty"` — the single file this phase owns — so the two
Embed phases no longer depend on their relative order (verified by
temporarily reversing the phase order and rebuilding: `BattyBroker`
survived). This half of the fix was correct on the first attempt and
unaffected by the `inputPaths` revert.

**Gotcha — do not wire `batty` as an Xcode package-product dependency.**
The original plan (both the old `docs/cli-tool-install.md` and #0249's
first attempt) was to have the app target depend on the `batty`
*executable product* directly and use a Copy Files build phase. That
approach was implemented and reverted within #0249 because it pulled the
`batty` executable into the `Batty (Prod)` scheme's build graph, which
broke `xcodebuild`'s test-runner resolution of `BattyKit`'s
`Bundle.module` resource bundle — every `BattyKitTests` test then crashed
on launch (`resource_bundle_accessor.swift: Fatal error: unable to find
bundle named BattyKit_BattyKit`). `swift test` run standalone does *not*
reproduce this, so it's easy to reintroduce by accident; the project's own
canonical gate (`scripts/build.sh unit`) is what catches it. The shipped
fix instead builds `batty` **from the package**, invoked from inside the
Run Script phase, so the executable product never enters the Xcode build
graph at all.

### 5. Installation to PATH

Implementation: `BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift`.
Reworked by issue `#0268` (porting back two `CLIInstaller` improvements
from the RemoteControl XPC experiment, see `docs/xpc/cli-embedding-and-install.md`)
to replace a bare `isInstalled() -> Bool` with a four-state inspection and
add a durability gate on the source bundle; `#0275` extended that durability
gate to also refuse a Gatekeeper-translocated bundle, with its own refusal
message (see the `isBundleDurable` bullet below); `#0277` made `installPath`
variant-aware — see "Variant-aware install path (#0277)" below before the
mechanism bullets. Full listing (Prod's default shown; the actual default
expression is `CLIInstaller.resolvedInstallPath()`, described below):

```swift
nonisolated struct CLIInstaller {
    enum State: Equatable, Sendable {
        case notInstalled
        case installedHere
        case installedElsewhere(String)
        case blockedByFile
    }

    let installPath: String
    private let bundleURL: URL
    private let fileManager: FileManager

    init(
        installPath: String = Self.resolvedInstallPath(),
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.installPath = installPath
        self.bundleURL = bundleURL
        self.fileManager = fileManager
    }

    var commandName: String {
        (installPath as NSString).lastPathComponent
    }

    static func resolvedInstallPath(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let variant = ServiceNames.Variant(bundleIdentifier: bundleIdentifier) else {
            return ServiceNames.Variant.prod.cliInstallPath
        }
        return variant.cliInstallPath
    }

    var bundledCLIPath: String? {
        bundleURL
            .appending(path: "Contents/Resources/bin/batty", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    var isBundleDurable: Bool {
        let path = bundleURL.path(percentEncoded: false)
        return !path.contains("/DerivedData/")
            && !path.contains("/Build/Products/")
            && !path.contains("/AppTranslocation/")
    }

    private var isBundleTranslocated: Bool {
        bundleURL.path(percentEncoded: false).contains("/AppTranslocation/")
    }

    func inspectInstallState() -> State {
        Self.inspect(installPath: installPath, expecting: bundledCLIPath, fileManager: fileManager)
    }

    static func inspect(installPath: String, expecting target: String?, fileManager: FileManager) -> State {
        guard let attributes = try? fileManager.attributesOfItem(atPath: installPath) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .blockedByFile
        }
        guard let resolved = try? fileManager.destinationOfSymbolicLink(atPath: installPath) else {
            return .notInstalled
        }
        guard let target, resolved == target else {
            return .installedElsewhere(resolved)
        }
        return .installedHere
    }

    func install() throws {
        guard let bundledPath = bundledCLIPath, fileManager.fileExists(atPath: bundledPath) else {
            throw CLIInstallerError.bundledBinaryNotFound
        }
        guard isBundleDurable else {
            let path = bundleURL.path(percentEncoded: false)
            throw isBundleTranslocated
                ? CLIInstallerError.bundleTranslocated(path)
                : CLIInstallerError.bundleNotDurable(path)
        }
        guard inspectInstallState() != .blockedByFile else {
            throw CLIInstallerError.blockedByFile(installPath)
        }

        let dir = shellEscape(
            URL(filePath: installPath).deletingLastPathComponent().path(percentEncoded: false)
        )
        let dst = shellEscape(installPath)
        let src = shellEscape(bundledPath)
        try runPrivileged(
            "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
            prompt: "Batty needs administrator access to install the CLI to /usr/local/bin."
        )
    }

    func uninstall() throws {
        let state = inspectInstallState()
        guard state != .notInstalled else { return }
        guard state != .blockedByFile else {
            throw CLIInstallerError.blockedByFile(installPath)
        }
        try runPrivileged(
            "rm -f \(shellEscape(installPath))",
            prompt: "Batty needs administrator access to uninstall the CLI from /usr/local/bin."
        )
    }

    // NSAppleScript must run on the main thread; callers are @MainActor.
    private func runPrivileged(_ command: String, prompt: String) throws {
        let cmd = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        let p = prompt.replacing("\"", with: "\\\"")
        let source = "do shell script \"\(cmd)\" with prompt \"\(p)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw CLIInstallerError.installFailed("Failed to prepare authorization script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            if (errorInfo?[NSAppleScript.errorNumber] as? Int) == -128 {
                throw CLIInstallerError.cancelled
            }
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? ""
            throw CLIInstallerError.installFailed(message)
        }
    }
}
```

### Variant-aware install path (#0277)

Both variants used to default `installPath` to the same
`/usr/local/bin/batty`, so installing from Beta silently repointed Prod's
symlink (whichever variant installed last owned the PATH command) — the
XPC broker was Prod-only at the time (#0270), so a Beta-driven `batty`
command could only fail closed anyway, but once Beta got its own working
broker (#0277) that collision became a real footgun.

Fix: `installPath`'s default is now `CLIInstaller.resolvedInstallPath()`,
which reads `Bundle.main.bundleIdentifier` and maps it to
`ServiceNames.Variant.cliInstallPath`:

- Prod → `/usr/local/bin/batty` (unchanged; no migration for existing installs).
- Beta → `/usr/local/bin/batty-beta`.
- An unrecognized bundle identifier (dev/test host, a fork) falls back to
  Prod's path rather than producing an unusable empty one.

`CLIInstaller.commandName` (the last path component of `installPath`)
drives the Settings → Advanced UI copy (`SettingsView.swift`) so it names
the actual installed command — `batty` or `batty-beta` — instead of
hardcoding `batty` for both variants. The two variants therefore coexist
on `PATH` without either being able to silently repoint the other's
symlink; #0268's four-state `inspectInstallState()` inspects each
variant's own path and never reports the other variant's symlink as its
own.

**User-visible consequence of #0277 as a whole** (not just the install
path): both variants now ship a working XPC broker and each gets its own
LaunchAgent, so a user running both Prod and Beta will see **two entries**
under System Settings → General → Login Items & Extensions, and launchd
carries two independent services (`co.sstools.Batty.broker`,
`co.sstools.Batty.beta.broker`). That is correct — each variant is fully
independent — not a bug to fix.

Mechanism, exactly:

- **Destination:** `/usr/local/bin/batty` for Prod, `/usr/local/bin/batty-beta`
  for Beta (see above), injectable via `init` (the injection seam exists
  for tests, not for a user-facing setting — the shipped app always uses
  the variant-derived default).
- **Symlink, not copy.** `install()` runs
  `mkdir -p /usr/local/bin && rm -f /usr/local/bin/batty && ln -s
  <bundle>/Contents/Resources/bin/batty /usr/local/bin/batty` as one
  privileged shell command — but only after `inspectInstallState()` has
  confirmed the destination is either absent or already a symlink.
- **Four-state inspection, not a boolean.** `inspectInstallState()` (backed
  by the static `inspect(installPath:expecting:fileManager:)` so it's
  testable without touching `/usr/local/bin`) returns one of `.notInstalled`,
  `.installedHere`, `.installedElsewhere(String)` (carries the stale
  target path), or `.blockedByFile`. It uses
  `FileManager.attributesOfItem(atPath:)` — which does **not** follow
  symlinks — to tell a symlink apart from a real file; `fileExists(atPath:)`
  would follow the link and misreport a dangling symlink (app deleted or
  moved) as "nothing installed" while a broken command still sat on `PATH`.
  Moving or renaming `Batty.app` now surfaces as `.installedElsewhere` (not
  silently `.notInstalled`), and the UI offers "Install" with a note about
  the stale target; re-running it self-heals by overwriting the stale
  symlink (`rm -f` before `ln -s` — unchanged from before, and still only
  reachable once the state check has ruled out `.blockedByFile`).
- **`.blockedByFile` refuses, and is checked before the privileged call.**
  A plain file at `/usr/local/bin/batty` (something the user put there
  directly, not a symlink Batty created) makes `install()` throw
  `CLIInstallerError.blockedByFile` *before* `runPrivileged` runs — the
  destructive `rm -f` never executes, no auth dialog fires for a doomed
  operation. `uninstall()` applies the identical guard so it never removes
  a file it didn't create.
- **`isBundleDurable` gates the source bundle, not the destination.**
  `install()` refuses (`CLIInstallerError.bundleNotDurable`) when the
  running `Batty.app`'s own bundle path contains `/DerivedData/` or
  `/Build/Products/` — the case where the app was launched straight from
  Xcode. Installing from there would create a symlink into a build product
  that a clean build deletes, surfacing days later as `batty: command not
  found` with nothing pointing back at the cause. A properly installed
  `/Applications/Batty.app` is unaffected; the check only looks at
  `bundleURL`, never at the `/usr/local/bin/batty` destination.
- **`isBundleDurable` also refuses a Gatekeeper-translocated bundle
  (`#0275`).** A user who downloads the release DMG and runs `Batty.app`
  straight from `~/Downloads` — without first dragging it to
  `/Applications` — gets Gatekeeper app translocation: macOS runs the app
  from a read-only, randomized `/private/var/folders/…/AppTranslocation/
  <uuid>/d/Batty.app` mount that reclaims itself the same way a
  `/DerivedData/` build does. That path contains neither `/DerivedData/`
  nor `/Build/Products/`, so before `#0275` it passed the check and
  installed a symlink into a mount macOS was going to reclaim — the exact
  failure the guard exists to prevent, reached by the *more common* route
  (a normal user, not a developer running from Xcode). The fix adds
  `/AppTranslocation/` to the same substring check (the documented, stable
  path-component form since macOS 10.12); `SecTranslocateIsTranslocatedURL`
  was considered and rejected — it is not in the public Security.framework
  SDK headers, so calling it would mean `dlopen`/`dlsym` plumbing for a
  predicate the substring already answers correctly. This case throws a
  distinct `CLIInstallerError.bundleTranslocated` (private
  `isBundleTranslocated` picks the branch) rather than reusing
  `.bundleNotDurable`, because the right advice for a translocated bundle
  differs from a build-folder bundle in one critical way: **a translocated
  instance stays translocated until relaunched**, even after the user
  drags the app to `/Applications`. `bundleTranslocated`'s message says so
  explicitly (drag to `/Applications`, *relaunch*, then try installing
  again) — telling a translocated user only to move the app, the
  `bundleNotDurable` wording, would have them click Install again in the
  still-translocated instance and hit the same refusal.
- **`#0279`:** both messages used to hardcode the literal `Batty.app` —
  correct for Prod, wrong for a `Batty Beta.app` bundle once `#0279` gave
  Beta its own `PRODUCT_NAME`. `errorDescription` now derives the app name
  from `(path as NSString).lastPathComponent` (the same `path` associated
  value already carries the full bundle path), so a Beta user reading the
  refusal sees "Batty Beta.app", not a name that names the wrong app.
- **Privilege escalation:** in-process `NSAppleScript` running `do shell
  script "..." with prompt "..." with administrator privileges` — this is
  what produces the standard macOS authorization dialog branded with the
  app's own name/icon (as opposed to shelling out to `/usr/bin/osascript`,
  which would brand the dialog as "osascript"/Script Editor). Must run on
  the main thread (the code comment says so explicitly, and callers are
  `@MainActor`); this was deliberately preserved by `#0268`, not moved to a
  background task, even though it means the cosmetic
  `.installing`/`.uninstalling` spinner gap below stays as-is. Every
  interpolated path is wrapped in single quotes via a private `shellEscape`
  helper (`'` → `'\''`) to survive spaces/quotes in bundle paths.
- **Cancellation:** `NSAppleScript`'s `AppleScript` error number `-128`
  (user declined/cancelled the auth prompt) is mapped to
  `CLIInstallerError.cancelled`; any other script error becomes
  `CLIInstallerError.installFailed(message)`. A missing bundled binary
  (shouldn't happen in a normal build) throws
  `CLIInstallerError.bundledBinaryNotFound`.
- **Uninstall** is a no-op if `inspectInstallState()` is already
  `.notInstalled`; refuses (`CLIInstallerError.blockedByFile`) for a plain
  file; otherwise a privileged `rm -f /usr/local/bin/batty` for
  `.installedHere` or `.installedElsewhere`.
- **Batty is unsandboxed** (`ENABLE_APP_SANDBOX = NO` in
  `Configuration/Build.xcconfig`), so unlike a sandboxed app this does
  *not* need the `com.apple.security.automation.apple-events` entitlement
  for `NSAppleScript`'s `do shell script` to work — confirmed by reading
  `Batty/Batty.entitlements` (only `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.allow-dyld-environment-variables` are present; no
  automation entitlement, no sandbox key at all).

**UI surface:** Settings → **Advanced** tab
(`BattyKit/Sources/BattyKit/Views/SettingsView.swift`). `SettingsView`'s
`TabView` includes `AdvancedSettingsView()` with `.tabItem { Label
("Advanced", systemImage: "terminal") }`. `AdvancedSettingsView` hosts a
single `Section("Command-Line Tool")` containing `CLIInstallRow`, driven
by an `@Observable` `CLIInstallModel` (states: `.checking`, `.installed`,
`.installedElsewhere(String)`, `.notInstalled`, `.blockedByFile`,
`.installing`, `.uninstalling`, `.failed(String)`) that maps
`CLIInstaller.State` onto its own state via `checkInstalled()`.
`onAppear` calls `cliModel.checkInstalled()`. The row shows an
"Install"/"Uninstall" button depending on state, a green checkmark when
installed, an orange caption naming the stale target for
`.installedElsewhere`, a red "already exists and isn't a symlink Batty
created" caption for `.blockedByFile`, and the underlying error message
(including the `bundleNotDurable` "move Batty.app to /Applications"
message) for `.failed`. One documented cosmetic gap: because
`NSAppleScript` blocks the main thread synchronously through the auth
dialog, the `.installing`/`.uninstalling` `ProgressView` states are set
but never actually get a chance to render before the call returns.

### 6. Signing, entitlements, notarization

**Updated by `#0273`, which independently measured this rather than
presuming it — the two claims this section used to make (Xcode's
automatic-signing pass re-signs a loose `Resources/bin/*` Mach-O; `#0249`'s
"re-signed by the app pass") are both **false** for a plain build action.**

- **Hardened Runtime** is on for the app (`ENABLE_HARDENED_RUNTIME = YES`
  in the Release/Debug build configurations of the `Batty` target in
  `project.pbxproj`).
- **Measured directly: nothing re-signs `bin/batty` during a plain
  `xcodebuild build`, in any configuration.** `#0273` ran real signed
  builds (`xcodebuild build`, Debug and Release, `CODE_SIGNING_ALLOWED=YES`)
  and inspected `Contents/Resources/bin/batty` with `codesign -dv` before
  and after the app's own codesign pass ran: it stayed **ad-hoc**
  (`flags=0x2(adhoc)`, `TeamIdentifier=not set`) throughout. This disproves
  `#0249`'s "re-signed by the app pass" note (below) as a general claim —
  whatever that observation was based on, it does not reproduce for a
  Resources-sealed loose Mach-O signed by a normal build.
- **Fix (`#0273`): the "Embed CLI" Run Script phase now signs `bin/batty`
  explicitly**, the same way the "Embed Broker" phase (`#0270`) already
  signed `BattyBroker` — `codesign --force --sign
  "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime …`, guarded on
  `CODE_SIGNING_ALLOWED`. Both binaries pick up a secure `--timestamp` only
  when `${ACTION} = install` (Xcode's Archive action, confirmed by
  instrumenting the phase and running a real `xcodebuild archive` — Archive
  builds with `ACTION=install` regardless of `CONFIGURATION`); every other
  build (including `-configuration Release build`) keeps
  `--timestamp=none` so it never depends on reaching Apple's timestamp
  authority over the network.
- **What happens during `-exportArchive` to a loose `Resources/bin/*`
  binary is still not independently verified end-to-end** — this
  machine's keychain holds only an `Apple Development` identity, no
  `Developer ID Application` certificate, so `#0273` could not run the
  real export step. What *is* measured: instrumenting the Embed phases and
  running a real `xcodebuild archive` (no export) shows both `bin/batty`
  and `BattyBroker`, inside the archive, signed with `Authority=Apple
  Development: Brennan Stehling (…)` — i.e. archive-time signing uses
  whatever identity Automatic signing resolves for that build, the same as
  the rest of the archived app at that point, not yet the Developer ID
  identity `-exportArchive` applies to the app bundle itself.
  `-exportArchive`'s re-signing is documented to reach **nested code**
  (`Contents/Frameworks/*`, the main executable); `Resources/bin/*` is
  sealed as a *resource*, not nested code (the same fact that makes
  `codesign --deep --strict` blind to it — see the traps in `issues/0270.md`
  and `issues/0273.md`), so the strong expectation is that export leaves
  these two binaries at whatever identity the archive-time Embed phase
  used, same as an ordinary build. **`scripts/release.sh` no longer relies
  on this being true either way**: right after export, it explicitly
  re-signs both binaries with the same Developer ID identity/options the
  app was just exported with, then re-signs the app bundle itself so its
  resource seal (`Contents/_CodeSignature/CodeResources`) reflects the
  now-modified files. Re-signing something already correctly signed is a
  no-op in effect, so this is safe regardless of what export turns out to
  do — but the underlying "does export touch it" question is still open;
  see `issues/0273.md` for the exact steps needed to close it (a Developer
  ID certificate plus a real, user-authorized release run).
- `#0249`'s verification log asserted, for a plain (non-notarized)
  `scripts/build.sh` run: "embedded binary confirmed at
  `Batty.app/Contents/Resources/bin/batty` (Mach-O 64-bit executable
  arm64, **re-signed by the app pass**)". `#0273` could not reproduce this
  under the same conditions (plain signed build, `codesign -dv` showed
  ad-hoc both before and after). Treat that earlier note as **superseded**,
  not as evidence of any re-signing mechanism — the CLI's signature only
  changed once `#0273` added an explicit `codesign` call to the Embed CLI
  phase.

### 7. Testing

Unit tests (Swift Testing, `BattyKit/Tests/BattyKitTests/`):

- **`SessionURLBuilderTests.swift`** — path resolution (`.`, relative,
  absolute, `~`, nonexistent path → nil, file-not-directory → nil),
  `buildURL` scheme/host correctness and percent-safe encoding of paths
  containing spaces, and `sessionPath(from:)` round-tripping plus
  rejection of wrong scheme/host.
- **`CLIInstallerTests.swift`** (`#0279` addition) — the `bundleNotDurable`/
  `bundleTranslocated` refusal messages name the app that's actually
  running (`Batty Beta.app`), not a hardcoded `Batty.app`.
- **`LoggingSubsystemTests.swift`** (`#0279`) — `BattyXPCCore.Logging
  .resolvedSubsystem` uses a given bundle identifier when present and
  falls back to the compile-time-baked `ServiceNames.appBundleIdentifier`
  (not a Prod literal) when `nil` — the bare-Mach-O broker/CLI path.
- **`SessionNameCacheTests.swift`** (`#0279`) — `resolvedDirectoryName`/
  `canonicalFileURL` keep Prod's path byte-identical and diverge to a
  distinct `Batty Beta` directory for the Beta bundle identifier.
- **`BattyURLHandlerRoutingTests.swift`** — the `#0251` regression suite:
  `initialWindowID` matches `windows[0]`'s id and is stable after
  additional `WindowRuntime`s are created; `anyContentWindowRuntime()` is
  `nil` with no registered `NSWindow` and resolves correctly once one is
  registered; `addSession(workingDirectory:)` lands in the correct
  runtime (not a phantom), selects the new session, and threads the
  working directory through to the new session's first tab's
  `terminal.configuration.workingDirectory`; an empty working directory is
  *not* forwarded (guards against overriding the shell default with an
  empty string); and an end-to-end `BattyURLHandler.handle(url:store:)`
  call from a built `SessionURLBuilder.buildURL` URL produces a selected
  session with the right working directory.

Run via the project's standard gate: `scripts/build.sh unit` (runs
`BattyKitTests` only, no UI, <30 s).

**Running the CLI standalone**, with no Xcode/app bundle involved:

```bash
cd BattyKit
swift build --product batty
swift run batty --help
swift run batty --version   # prints "unknown" — no host app Info.plist to read
swift run batty /some/existing/dir
```

This is also the fastest way to iterate on `BattyCLI.swift`/
`SessionCommand.swift`/`SessionURLBuilder.swift` without rebuilding the
whole app — but note it does **not** exercise the embedded-in-bundle
runtime environment (rpath resolution, `--version`'s Info.plist lookup,
the installed-symlink path), which is exactly the gap that let `#0252`'s
crash ship unnoticed.

There is no dedicated UI-test coverage of the CLI itself (installing via
the Settings row, the live authorization dialog, or an actual end-to-end
`batty <path>` against a running app) — every issue that touched this area
(`#0249`, `#0250`, `#0251`) explicitly calls out that the live round-trip
needs a human's runtime sign-off and cannot be verified headlessly.

### 8. Known limitations

Grounded directly in the code above, not aspirational:

- **One-way, fire-and-forget.** `openURL` in `SessionCommand.swift` only
  observes whether `/usr/bin/open` itself launched and exited zero — it
  has no visibility into whether `BattyURLHandler.handle` ran, whether
  `SessionURLBuilder.sessionPath(from:)` parsed the URL successfully, or
  whether a session was actually created. A `batty /valid/dir` that
  reaches a running-but-broken Batty will still exit `0`.
  `issues/0257.md` §"IPC decision (pinned, amended)" pins this
  explicitly: "mutations go over the `batty://` URL scheme (fire-and-
  forget, no daemon)" as the deliberate near-term architecture; a
  request/response Unix socket is explicitly deferred ("Tier 3") for
  anything needing a live reply (`read` a screen, `wait`, `send` input,
  `events`).
- **No meaningful exit code for app-side failure.** Exit code `1` from
  `batty` today only ever means "the CLI itself" rejected the input
  (bad path) or `open` failed to run — never "the app rejected the
  request" (there is no such response path) or "the app isn't installed/
  registered for the scheme" (in that case `open` typically still exits 0
  having handed the URL to Launch Services, or fails with its own
  Launch-Services-level error, not a Batty-specific one).
- **Query surface, updated as of #0281.** `issues/0257.md` originally
  proposed (as an *unimplemented* plan) a debounced, atomically-written
  JSON topology snapshot on disk (`~/Library/Application Support/Batty/
  state.json`) as a lightweight read path that avoids standing up a
  socket, plus a `batty whoami` verb reading `BATTY_*` env vars injected
  into spawned shells. The snapshot plan was dropped by #0274 in favor of
  live `batty list`/`batty session info` over XPC (see that issue's
  Resolution notes) — those still require the app/broker to be reachable.
  The env-var half shipped separately in #0281: `BATTY_SESSION_ID`/
  `BATTY_PANE_ID`/`BATTY_TAB_ID` are injected into every surface at spawn
  (`TabRuntime.applyShellAndAppearancePreferences`, via libghostty's `env =`
  config directive), and `batty id [--json]` (alias `whoami`) reads them
  with **no app round-trip** — it works even when the app/broker is
  unreachable, which is what distinguishes it from `list`/`session info`.
- **First mutating XPC verb, #0282.** `batty pane split [-h|--horizontal |
  -v|--vertical] [-c|--command <cmd>] [--pane <id>] [--view <kind>]` splits
  the calling/target pane and prints the new pane's id to stdout on
  success. (`--view` is #0315, documented in its own entry below.)
  Unlike every verb above, this one *mutates* app state, which is exactly
  why it went over the XPC request/reply channel rather than the one-way
  `batty://` scheme (see `issues/0257.md`'s 2026-07-26 transport
  amendment): a stale/unknown `--pane` id is a visible failure (exit `4`),
  not a silent no-op. Defaults to horizontal when no direction flag is
  given. `--pane` falls back through the same chain as `session info`'s
  `--session` (explicit flag → `BATTY_PANE_ID` env → the app's focused
  pane) via `BattyTargetResolver`. `-c`/`--command` **replaces** the shell
  preference entirely for that one pane rather than appending to it — the
  new pane's `command =` line is either the override or the configured
  shell, never both, so with a custom shell configured the override
  bypasses that shell (and any shell-integration behavior it provides,
  notably OSC 7 cwd reporting) entirely. `-c` panes also set libghostty's
  `wait-after-command = true` for that one pane, so the pane survives its
  command exiting instead of closing immediately — output stays readable
  until the pane is closed deliberately. This is scoped to `-c` panes
  only: a pane with no command override keeps today's behavior (closes
  when its shell exits), so Cmd-D and every existing tab are unaffected.
  `wait-after-command` was verified against the pinned libghostty
  (`b146b73a8ba3ed2678a22a9de5feecfcbf298d48`, tag 1.3.2) directly — `false`
  by default, `true` accepted with zero config diagnostics — rather than
  assumed from the directive's name.
- **`--view <kind>` on `pane split`, #0315.** Selects the new pane's content
  kind — `terminal` (the default when the flag is omitted; every existing
  `pane split` invocation keeps producing a terminal pane unchanged),
  `git-status`, `process-status`, `lm-studio-dashboard`, or
  `system-metrics`. An unknown kind is rejected client-side with exit `1`
  before any XPC round trip, listing the valid set. Non-terminal kinds
  render as a deliberately provisional placeholder today — #0301's
  design-first gate means none of their real views has an approved design
  yet (see `docs/design/*.md`); the plumbing (model field, wire field, CLI
  flag) is what this issue ships, not the views themselves. `-c/--command`
  presumes a shell, so it is rejected client-side (exit `1`) when combined
  with a non-terminal `--view`. `pane close` needs no changes to close a
  non-terminal pane — see `docs/pane-kinds.md` §5. Review round 1 found and
  fixed several places that treated a non-terminal pane's one structural
  `TabRuntime` as a real Tab (Cmd-T, `batty status`/`batty list --tabs`,
  the quit-confirmation count, the sidebar pane label, and a
  `TerminalHostStore.placements` leak on hide) — see `docs/pane-kinds.md`'s
  `#0315` implementation note for the full list.
- **Second mutating XPC verb, #0283.** `batty pane close [--pane <id>]` ends
  **every** Tab's Terminal Session in the calling/target pane — not just the
  active one — and removes the pane's region from the split tree, the
  sibling subtree taking over the space. This is **pane-level** close, and
  is deliberately distinct from `tab close` (closing one tab, removing the
  pane only when that was its last): an agent that wants the smaller
  operation must reach for `tab close`, not this verb. `--pane` resolves
  through the same `BattyTargetResolver` chain as `pane split`. Three
  distinct conditions all report the same visible failure (exit `4`, not a
  silent no-op): an unknown/stale `--pane` id; a pane holding a Tab that
  libghostty reports as still needing close confirmation, which is refused
  outright rather than silently bypassed (there is no UI for an XPC caller
  to confirm in) or force-killed unasked; and closing what would be the
  app's very last pane across every window, refused so an unattended agent
  cannot chain a single command into quitting Batty with no confirmation
  dialog — the same silent-quit shape tracked (for the shell-exit path) by
  `issues/0217.md`. Closing a non-last pane that was its session's last
  closes that session, mirroring the existing `closeTab` cascade; closing
  the tree's focused pane moves focus to the pane that absorbs its space,
  so `focusedPaneID` never dangles on a removed pane. On success there is
  nothing to chain on (unlike `pane split`'s new-pane id), so the CLI prints
  nothing and exits `0`.
- **Third mutating XPC verb, #0284 — the agent loop's terminal step.**
  `batty notify --title <t> [--body <b>] [--sound] [--tab <id>]` posts an
  entry into the Bell Feed — a long-running agent's way to say "done" or
  "I need input" without the user watching that pane. Went to XPC for the
  same reason `pane split`/`pane close` did: `notify` is the *last* step of
  the agent loop, so a silent failure here ("the agent believes the user
  was told, but nothing happened") is the least recoverable in the whole
  chain, and `batty://`'s only edge over XPC — launching a not-yet-running
  app — is worthless when posting into that app's feed is the entire
  point. `--tab` resolves through the same `BattyTargetResolver` chain as
  `pane split`/`pane close`'s `--pane`, one tier further down (a
  `BellFeedEntry` needs a real tab, not merely a real pane): explicit flag
  → `BATTY_TAB_ID` env → the app's focused tab. There is deliberately no
  placeholder-id path — an unresolvable target (unknown/stale `--tab`, or
  no tab resolvable at all) is a visible failure (exit `4`), not a feed row
  stuffed with dead ids. `notify` reuses the existing `BellFeedEntry`
  shape unmodified (no new kind field): a resolved real tab means
  click-to-jump, cleanup-on-tab-close, per-session mute, and AI
  summarization all apply exactly as they do to a BEL/OSC-9 entry. `--body`
  is optional; the feed row's message is the title alone, or
  `"<title>\n<body>"` when a body is given. `--sound` requests sound on
  this one notification, gated by (never overriding) Settings →
  Notifications → "Play sound" — omitting it posts silently regardless of
  that toggle. On success there is nothing to chain on, so the CLI prints
  nothing and exits `0`, matching `pane close`. See `docs/notifications.md`
  for the full pipeline this rides.
- **The rest of the command surface is still growing.** `session`/`pane`
  now each have real subcommands (`session info`, `pane split`, `pane
  close`), and the bare `notify` verb has shipped, but the full
  `session`/`pane`/`tab`/`window` noun/verb grammar, `--json` on every
  verb, client-generated ids for chaining, and the `open` bare verb remain
  `issues/0257.md`'s (open) Tier 0 + Tier 1 proposal — see that issue's
  "Children and gating order" table for what has and hasn't shipped.
- **Cold-launch double-session.** As noted in the trace above, `batty
  <path>` against a not-yet-running Batty produces both the default
  cold-launch session and the requested-path session — acceptable per
  `#0251`'s own notes, but a real behavior a caller should expect, not
  a bug to work around blindly.

## File inventory

| File | Role |
|---|---|
| `BattyKit/Package.swift` | Declares the `BattyCLICore` target (dependency-free), the `BattyKit` library target (depends on `BattyCLICore`, GhosttyKit/Terminal/Theme, SlidingTabs, Sparkle, Textual), and the `batty` executable target/product (depends on `BattyCLICore` + `ArgumentParser` only). |
| `BattyKit/Sources/batty/BattyCLI.swift` | `@main` entry point; argument parsing (`swift-argument-parser`); orchestrates resolve → build URL → open. |
| `BattyKit/Sources/batty/SessionCommand.swift` | `resolveAppVersion()` (reads the host app's `Info.plist`), `resolvePath(_:)`, `openURL(_:bundleIdentifier:)` (spawns `/usr/bin/open -b <bundleIdentifier>`, defaulting to `ServiceNames.appBundleIdentifier` — `#0279`). |
| `BattyKit/Sources/BattyCLICore/SessionURLBuilder.swift` | `resolve`/`buildURL`/`sessionPath` — the shared wire format between CLI, app, and tests. |
| `BattyKit/Sources/BattyKit/BattyCLICoreReexport.swift` | `@_exported import BattyCLICore` so existing `import BattyKit` consumers keep seeing `SessionURLBuilder`. |
| `BattyKit/Sources/BattyKit/Runtime/BattyURLHandler.swift` | App-side handler: parses the `batty://` URL, calls `AppStateStore.addSession(workingDirectory:)` on the main actor; logs and ignores unrecognized URLs. |
| `Batty/BattyApp.swift` | `BattyAppDelegate.application(_:open:)` routes `batty://` URLs to the handler; `.handlesExternalEvents(matching: Set())` on the content `WindowGroup` and Help `Window` suppresses SwiftUI's own stray-window behavior for the same event; `WindowGroup`'s `defaultValue` reuses `AppStateStore.shared.initialWindowID` so the URL-added session lands in the real on-screen window. |
| `Configuration/Info.plist` | Registers the `batty` URL scheme via `CFBundleURLTypes`/`CFBundleURLSchemes` (literal plist, not a build setting). |
| `BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift` | Symlink install/uninstall to a variant-derived path (`/usr/local/bin/batty` Prod, `/usr/local/bin/batty-beta` Beta — `#0277`), privileged via in-process `NSAppleScript`; four-state `inspectInstallState()` and `isBundleDurable` (`#0268`), extended to refuse a Gatekeeper-translocated bundle with its own error/message (`#0275`); refusal copy derives the app name from the bundle path instead of a hardcoded `Batty.app` (`#0279`). |
| `BattyKit/Sources/BattyKit/Views/SettingsView.swift` | Settings → Advanced tab; `CLIInstallModel` (`@Observable`) + `CLIInstallRow` UI driving `CLIInstaller`. |
| `Batty.xcodeproj/project.pbxproj` | The `Batty` native target's `Embed CLI` Run Script build phase (`alwaysOutOfDate = 1`, runs before the `Embed Broker` phase) that builds `batty` from the package via `xcrun swift build --product batty` and copies it to `Contents/Resources/bin/batty`. |
| `Configuration/Build.xcconfig` | `ENABLE_APP_SANDBOX = NO` (relevant: no automation-events entitlement needed for `NSAppleScript`); `CODE_SIGN_STYLE = Automatic`. |
| `Batty/Batty.entitlements` | Confirms no sandbox key and no `com.apple.security.automation.apple-events` entry. |
| `scripts/release.sh` | Archive/export/notarize pipeline; no CLI-specific signing step found — relies on `xcodebuild archive`/`-exportArchive`'s automatic signing plus a generic `codesign --verify --deep --strict` gate. |
| `BattyKit/Tests/BattyKitTests/SessionURLBuilderTests.swift` | Unit tests for path resolution and URL build/parse. |
| `BattyKit/Tests/BattyKitTests/BattyURLHandlerRoutingTests.swift` | Unit tests for the `#0251` window-targeting/working-directory-propagation fix. |
| `BattyKit/Tests/BattyKitTests/CLIInstallerTests.swift` | Includes `#0279`'s per-variant refusal-copy test. |
| `BattyKit/Tests/BattyKitTests/LoggingSubsystemTests.swift` | `#0279`: `BattyXPCCore.Logging.resolvedSubsystem` per-variant fallback. |
| `BattyKit/Tests/BattyKitTests/SessionNameCacheTests.swift` | Includes `#0279`'s per-variant cache-directory tests. |
| `BattyKit/Sources/BattyKit/Model/SessionNameCache.swift` | `resolvedDirectoryName`/`canonicalFileURL` derive the Application Support directory from the running variant's bundle identifier instead of a hardcoded `"Batty"` literal — Prod's path stays byte-identical (`#0279`). |
| `BattyKit/Sources/BattyXPCCore/Logging.swift`, `BattyKit/Sources/batty/Logging.swift`, `BattyKit/Sources/BattyBroker/Logging.swift` | The bare-Mach-O broker/CLI logging-subsystem fallback now resolves to `ServiceNames.appBundleIdentifier` (the compile-time-baked variant) instead of the Prod literal (`#0279`). |
| `Configuration/Beta.xcconfig` | `PRODUCT_NAME = Batty Beta` so the Beta build produces a distinctly-named bundle that can sit in `/Applications` next to `Batty.app` (`#0279`). |
| `scripts/build-beta.sh` | Builds the Beta scheme (unsigned by default, `--sign` opt-in), leaves the product at `beta-build/Products/Batty Beta.app`, and never copies into `/Applications` or touches the running Prod app (`#0279`). |
| `issues/0249.md` | Filed/resolved: CLI target + install plumbing. Source of the `BattyKit`-product-dependency trap warning. |
| `issues/0250.md` | Filed/resolved: `batty <path>` verb, `batty://` scheme, `@main` entry point rename. |
| `issues/0251.md` | Filed/resolved: fixed phantom-window and stray-SwiftUI-window bugs in the URL round-trip (two rounds). |
| `issues/0252.md` | Filed/resolved: `BattyCLICore` split to fix the Sparkle `@rpath` crash. |
| `issues/0257.md` | Open: pinned IPC decision (`batty://`, fire-and-forget, socket deferred) and an unimplemented `batty <noun> <verb>` design. |
| `docs/batty-cli-design.md` | Forward-looking design catalog for the CLI's verb surface — not as-built. |

## Where this diverges from `docs/cli-tool-install.md`

`docs/cli-tool-install.md` is a design survey of *supacode*'s CLI
installer plus a step-by-step plan to replicate it for Batty, written
before (and partially updated during) the work in `#0249`. Concretely,
compared to what's actually shipped:

- **The CLI executable target's dependency is different from the plan.**
  `docs/cli-tool-install.md` §4.1 shows `.executableTarget(name: "batty",
  dependencies: ["BattyKit", ...])` — "the payoff: share the model
  layer." The shipped target depends on **`BattyCLICore`**, a
  dependency-free target carved *out of* `BattyKit` specifically because
  the `BattyKit`-dependency approach crashed the embedded binary at
  launch (`#0252`, the `@rpath`/Sparkle issue described in full above).
  `docs/cli-tool-install.md` predates this fix and was never updated to
  reflect the `BattyCLICore` split — a reader following its §4.1 literally
  today would reintroduce the crash.
- **The build-embed mechanism in §4.2 does match the shipped
  implementation** (build-from-package inside a Run Script phase, not an
  Xcode package-product dependency) — that part of the old doc *was*
  corrected during `#0249` after the product-dependency approach broke the
  unit-test gate, and the script body is essentially identical to what's
  in `project.pbxproj` today.
- **The CLI ↔ app communication mechanism is different from what the old
  doc flags as an open question.** `docs/cli-tool-install.md` §5 lists
  "CLI ↔ app communication" as something to "design ... separately," citing
  supacode's local-socket (`SocketCommand`/`bin/zmx`) approach as the
  reference precedent. The shipped mechanism is the `batty://` custom URL
  scheme described throughout this document — no socket, no daemon,
  fire-and-forget. `issues/0257.md` later pinned this as the deliberate
  architecture for all *mutations*, with a two-way Unix socket explicitly
  deferred to a future tier for anything needing a live reply.
- **The old doc has no knowledge of the actual command surface at all** —
  it's scoped purely to install plumbing (`version`/`help` CLI, install/
  uninstall to `/usr/local/bin`) and predates `batty <path>` session
  creation, the `batty://` scheme, `BattyURLHandler`, and the window-
  targeting fixes in `#0251` entirely.
