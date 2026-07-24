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
`BattyKit` Swift package and copied into `Batty.app/Contents/Resources/bin/batty`
at app-build time. The Batty macOS app can install a symlink to it at
`/usr/local/bin/batty` from Settings → Advanced, after which `batty` is on
the user's normal shell `PATH`. Today the CLI does exactly one thing:
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

5. `openURL(url)` (`SessionCommand.swift`) spawns `/usr/bin/open
   <url-string>` via `Foundation.Process`, waits for it to exit
   synchronously, and propagates failure: a non-zero `open` exit status or
   a spawn error both produce a stderr message and `ExitCode.failure`.
   `open` itself launches Batty if it isn't running, or activates it if it
   is, and delivers the URL through the standard macOS
   Launch-Services/URL-event mechanism — no code in Batty has to poll or
   listen for this beyond registering the URL scheme (step 6). This is the
   full extent of the CLI's own work: it never talks to the app directly.

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

nonisolated func openURL(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
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
  matches there.
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
Script) → **`Embed CLI`** (Run Script, last).

The `Embed CLI` phase (`project.pbxproj`, phase id
`26B100020000000000000002`), verbatim:

```bash
set -euo pipefail
config="$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')"
archflags=()
for a in ${ARCHS}; do archflags+=(--arch "$a"); done
cd "${SRCROOT}/BattyKit"
xcrun swift build --product batty -c "${config}" "${archflags[@]}"
built="$(xcrun swift build --product batty -c "${config}" "${archflags[@]}" --show-bin-path)/batty"
dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
rm -rf "${dest}"
mkdir -p "${dest}"
/bin/cp -f "${built}" "${dest}/batty"
```

Its declared output path is
`$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/batty`, i.e.
`Batty.app/Contents/Resources/bin/batty` — this is a plain `cp`, run as an
inline shell script build phase on the app target; the CLI is **not**
wired in as an Xcode package-product dependency (see the Gotcha below for
why not). `CONFIGURATION` is `debug` or `release` (lowercased for `swift
build -c`); `ARCHS` becomes one or more `--arch` flags, which SwiftPM
resolves to a single universal binary at one `--show-bin-path` when
multiple arches are requested. Confirmed by inspecting a real Debug build
product (`~/Library/Developer/Xcode/DerivedData/Batty-*/Build/Products/Debug/Batty.app/Contents/Resources/bin/batty`):
present, `2,553,104` bytes, `file` reports `Mach-O 64-bit executable
arm64`.

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

Implementation: `BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift`,
full listing:

```swift
nonisolated struct CLIInstaller {
    private static let installPath = "/usr/local/bin/batty"

    static var bundledCLIPath: String? {
        Bundle.main.resourceURL?
            .appending(path: "bin/batty", directoryHint: .notDirectory)
            .path(percentEncoded: false)
    }

    func isInstalled() -> Bool {
        guard let bundledPath = Self.bundledCLIPath,
              let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.installPath)
        else { return false }
        return dest == bundledPath
    }

    func install() throws {
        guard let bundledPath = Self.bundledCLIPath,
              FileManager.default.fileExists(atPath: bundledPath)
        else { throw CLIInstallerError.bundledBinaryNotFound }

        let dir = shellEscape(
            URL(filePath: Self.installPath)
                .deletingLastPathComponent()
                .path(percentEncoded: false)
        )
        let dst = shellEscape(Self.installPath)
        let src = shellEscape(bundledPath)
        try runPrivileged(
            "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
            prompt: "Batty needs administrator access to install the CLI to /usr/local/bin."
        )
    }

    func uninstall() throws {
        guard isInstalled() else { return }
        try runPrivileged(
            "rm -f \(shellEscape(Self.installPath))",
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

Mechanism, exactly:

- **Destination:** `/usr/local/bin/batty`, hardcoded.
- **Symlink, not copy.** `install()` runs
  `mkdir -p /usr/local/bin && rm -f /usr/local/bin/batty && ln -s
  <bundle>/Contents/Resources/bin/batty /usr/local/bin/batty` as one
  privileged shell command. `isInstalled()` is true only when the symlink
  target **exactly equals** the current bundle's embedded-binary path
  (`FileManager.destinationOfSymbolicLink(atPath:)` compared against
  `bundledCLIPath`). Consequence: moving or renaming `Batty.app` makes
  `isInstalled()` report `false` even though a symlink still exists at
  `/usr/local/bin/batty` (it now points at a stale path) — the UI would
  then offer "Install" again, and re-running it self-heals by overwriting
  the stale symlink (`rm -f` before `ln -s`).
- **Privilege escalation:** in-process `NSAppleScript` running `do shell
  script "..." with prompt "..." with administrator privileges` — this is
  what produces the standard macOS authorization dialog branded with the
  app's own name/icon (as opposed to shelling out to `/usr/bin/osascript`,
  which would brand the dialog as "osascript"/Script Editor). Must run on
  the main thread (the code comment says so explicitly, and callers are
  `@MainActor`). Every interpolated path is wrapped in single quotes via a
  private `shellEscape` helper (`'` → `'\''`) to survive spaces/quotes in
  bundle paths.
- **Cancellation:** `NSAppleScript`'s `AppleScript` error number `-128`
  (user declined/cancelled the auth prompt) is mapped to
  `CLIInstallerError.cancelled`; any other script error becomes
  `CLIInstallerError.installFailed(message)`. A missing bundled binary
  (shouldn't happen in a normal build) throws
  `CLIInstallerError.bundledBinaryNotFound`.
- **Uninstall** is a no-op if `isInstalled()` is already `false`;
  otherwise a privileged `rm -f /usr/local/bin/batty`.
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
`.notInstalled`, `.installing`, `.uninstalling`, `.failed(String)`).
`onAppear` calls `cliModel.checkInstalled()`. The row shows an
"Install"/"Uninstall" button depending on state, a green checkmark when
installed, and an inline error message when `.failed`. One documented
cosmetic gap: because `NSAppleScript` blocks the main thread synchronously
through the auth dialog, the `.installing`/`.uninstalling` `ProgressView`
states are set but never actually get a chance to render before the
call returns.

### 6. Signing, entitlements, notarization

- **Hardened Runtime** is on for the app (`ENABLE_HARDENED_RUNTIME = YES`
  in the Release/Debug build configurations of the `Batty` target in
  `project.pbxproj`).
- **The embed phase does not itself codesign `bin/batty`** — it is a
  plain `cp`. Inspecting a locally-built Debug app
  (`Batty.app/Contents/Resources/bin/batty`) shows an **ad-hoc** signature
  (`codesign -dv` reports `flags=0x2(adhoc)`, `TeamIdentifier=not set`),
  which is a byproduct of SwiftPM/Swift toolchain ad-hoc-signing Mach-O
  executables at build time on Apple Silicon (required for arm64 code to
  run at all), not anything Batty's build does deliberately.
- **What happens to that signature during a real Release/notarized build
  is not fully verified from static inspection alone.** `#0249`'s own
  verification notes flag this explicitly as unverified ("Universal/Release
  arch path is unverified... only the single-arch Debug build was
  exercised"), and `#0252` repeats the same caveat. `scripts/release.sh`
  (read, not run, per project rules) runs `xcodebuild archive` +
  `xcodebuild -exportArchive` with `signingStyle: automatic` and then
  `codesign --verify --deep --strict --verbose=2 "$APP_PATH"` as a
  post-export gate — but the script contains **no line that specifically
  names `bin/batty`, `Resources/bin`, or re-signs a loose executable**;
  grepping the whole script for `batty`/`bin/batty`/`codesign` turns up
  only the generic post-export verification and the DMG-signing step
  further down. In other words: the mechanism that gets `bin/batty` from
  "ad-hoc signed by swift build" to "signed with the Developer ID identity
  + hardened runtime + secure timestamp that Apple's notarization service
  requires for every executable in the bundle" is presumed to be Xcode's
  own automatic-signing pass during `xcodebuild archive`/`-exportArchive`
  (which is documented by Apple to re-sign bundle contents, including
  loose Mach-O binaries, as part of producing a distributable archive),
  but this repo does not contain code that proves it, and no notarized
  build was inspected as part of writing this doc (per the "never run
  `release.sh` autonomously" rule). **Treat this as not independently
  verified** if you are relying on the exact signing state of the shipped
  `bin/batty` for a security-sensitive design.
- `#0249`'s verification log does assert, for a plain (non-notarized)
  `scripts/build.sh` run: "embedded binary confirmed at
  `Batty.app/Contents/Resources/bin/batty` (Mach-O 64-bit executable
  arm64, **re-signed by the app pass**)" — i.e. the app-level codesign
  pass that Xcode runs even for a local build does touch it. This is
  consistent with, but not the same guarantee as, notarization-grade
  signing.

### 7. Testing

Unit tests (Swift Testing, `BattyKit/Tests/BattyKitTests/`):

- **`SessionURLBuilderTests.swift`** — path resolution (`.`, relative,
  absolute, `~`, nonexistent path → nil, file-not-directory → nil),
  `buildURL` scheme/host correctness and percent-safe encoding of paths
  containing spaces, and `sessionPath(from:)` round-tripping plus
  rejection of wrong scheme/host.
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
- **No way for the CLI to observe app state.** There is no query surface
  at all today — no "list sessions," no "am I even running," nothing.
  `issues/0257.md` proposes (as an *unimplemented* plan) a debounced,
  atomically-written JSON topology snapshot on disk
  (`~/Library/Application Support/Batty/state.json`) as a lightweight
  read path that avoids standing up a socket, plus a `batty whoami`
  verb that would read `BATTY_*` environment variables injected into
  spawned shells — **none of this env-var injection or snapshot writing
  exists in the current codebase**; `BattyURLHandler.swift` and
  `AppStateStore.addSession` contain no code that sets `BATTY_SESSION_ID`/
  `BATTY_PANE_ID`/`BATTY_TAB_ID` or writes any state file. Treat
  `docs/batty-cli-design.md` and `issues/0257.md` as forward-looking
  design material, not current behavior.
- **The command surface is a single positional argument.** No
  `session`/`pane`/`tab`/`window` noun/verb grammar, no `--json`, no
  client-generated ids for chaining commands, no `notify`/`open` bare
  verbs — all of that is `issues/0257.md`'s (open, unimplemented) Tier 0 +
  Tier 1 proposal.
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
| `BattyKit/Sources/batty/SessionCommand.swift` | `resolveAppVersion()` (reads the host app's `Info.plist`), `resolvePath(_:)`, `openURL(_:)` (spawns `/usr/bin/open`). |
| `BattyKit/Sources/BattyCLICore/SessionURLBuilder.swift` | `resolve`/`buildURL`/`sessionPath` — the shared wire format between CLI, app, and tests. |
| `BattyKit/Sources/BattyKit/BattyCLICoreReexport.swift` | `@_exported import BattyCLICore` so existing `import BattyKit` consumers keep seeing `SessionURLBuilder`. |
| `BattyKit/Sources/BattyKit/Runtime/BattyURLHandler.swift` | App-side handler: parses the `batty://` URL, calls `AppStateStore.addSession(workingDirectory:)` on the main actor; logs and ignores unrecognized URLs. |
| `Batty/BattyApp.swift` | `BattyAppDelegate.application(_:open:)` routes `batty://` URLs to the handler; `.handlesExternalEvents(matching: Set())` on the content `WindowGroup` and Help `Window` suppresses SwiftUI's own stray-window behavior for the same event; `WindowGroup`'s `defaultValue` reuses `AppStateStore.shared.initialWindowID` so the URL-added session lands in the real on-screen window. |
| `Configuration/Info.plist` | Registers the `batty` URL scheme via `CFBundleURLTypes`/`CFBundleURLSchemes` (literal plist, not a build setting). |
| `BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift` | Symlink install/uninstall to `/usr/local/bin/batty`, privileged via in-process `NSAppleScript`. |
| `BattyKit/Sources/BattyKit/Views/SettingsView.swift` | Settings → Advanced tab; `CLIInstallModel` (`@Observable`) + `CLIInstallRow` UI driving `CLIInstaller`. |
| `Batty.xcodeproj/project.pbxproj` | The `Batty` native target's `Embed CLI` Run Script build phase (last phase) that builds `batty` from the package via `xcrun swift build --product batty` and copies it to `Contents/Resources/bin/batty`. |
| `Configuration/Build.xcconfig` | `ENABLE_APP_SANDBOX = NO` (relevant: no automation-events entitlement needed for `NSAppleScript`); `CODE_SIGN_STYLE = Automatic`. |
| `Batty/Batty.entitlements` | Confirms no sandbox key and no `com.apple.security.automation.apple-events` entry. |
| `scripts/release.sh` | Archive/export/notarize pipeline; no CLI-specific signing step found — relies on `xcodebuild archive`/`-exportArchive`'s automatic signing plus a generic `codesign --verify --deep --strict` gate. |
| `BattyKit/Tests/BattyKitTests/SessionURLBuilderTests.swift` | Unit tests for path resolution and URL build/parse. |
| `BattyKit/Tests/BattyKitTests/BattyURLHandlerRoutingTests.swift` | Unit tests for the `#0251` window-targeting/working-directory-propagation fix. |
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
