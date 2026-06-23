# Installing a `batty` CLI tool to `/usr/local/bin`

How to ship a command-line tool (`batty`) inside the Batty app bundle and
install it to `/usr/local/bin/batty` from the app's UI, modeled on how the
reference project **supacode** installs `/usr/local/bin/supacode`.

This guide is for a Batty engineer. It explains supacode's exact mechanism
(with file/line references into `../supacode`), then a step-by-step plan to
replicate it for `batty`, and the gotchas.

**Batty deviates from supacode in one deliberate way:** supacode defines its CLI
as a standalone Xcode (Tuist) command-line-tool target. Batty instead defines
the CLI as an **`executableTarget` inside the `BattyKit` Swift package**. The
governing principle for Batty is *keep as much code as possible in the Swift
package* — the CLI needs the model layer (`Session`, `Pane`, `Tab`,
`SplitNode`, workspace types, any app-IPC client), all of which live in
BattyKit, so the CLI is built from the package and `import`s `BattyKit`
directly. The app bundle just embeds the built binary. The privilege-escalation
and install mechanics are otherwise identical to supacode.

---

## 1. Summary of supacode's approach

supacode does the simplest thing that works and avoids a privileged helper
entirely:

1. **The CLI is a separate Xcode (Tuist) target** that builds a normal
   command-line executable named `supacode`.
2. **A post-build script copies that executable into the app bundle** at
   `Contents/Resources/bin/supacode`.
3. **At install time the app creates a symlink** at `/usr/local/bin/supacode`
   pointing back into the bundle's `Resources/bin/supacode`.
4. **Privilege escalation is done with `NSAppleScript` running
   `do shell script ... with administrator privileges`** — this triggers the
   standard macOS authorization (password / Touch ID) dialog, branded with the
   app's icon and name. No `SMJobBless`, no `AuthorizationServices` C API, no
   XPC privileged helper, no separate `osascript` process.

The install is a **symlink, not a copy**. `isInstalled()` is true only when the
symlink resolves to the *current* bundle path, so moving/renaming the app
quietly makes it "not installed" and a re-install fixes it.

I verified there is **no** `SMJobBless`, `AuthorizationExecuteWithPrivileges`,
`AuthorizationCreate`, XPC, or ServiceManagement usage anywhere in the supacode
sources — `NSAppleScript` in `CLIInstaller.swift` is the only escalation path.

---

## 2. The exact mechanism (with supacode references)

### 2.1 The installer — `CLIInstaller.swift`

`../supacode/SupacodeSettingsShared/BusinessLogic/CLIInstaller.swift`

The whole thing is ~95 lines. Key parts:

Install path and bundle lookup (lines 3-19):

```swift
nonisolated struct CLIInstaller {
  private static let installPath = "/usr/local/bin/supacode"

  /// Returns the path to the CLI binary inside the app bundle.
  static var bundledCLIPath: String? {
    Bundle.main.resourceURL?
      .appending(path: "bin/supacode", directoryHint: .notDirectory)
      .path(percentEncoded: false)
  }

  func isInstalled() -> Bool {
    guard let bundledPath = Self.bundledCLIPath else { return false }
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.installPath) else {
      return false
    }
    return dest == bundledPath
  }
```

Note `isInstalled()` compares the symlink *target* against the current bundle
path, so an app that moved reads as not-installed.

Install (lines 21-38) — builds a single `mkdir && rm -f && ln -s` shell command
and runs it privileged:

```swift
  func install() throws {
    guard let bundledPath = Self.bundledCLIPath else {
      throw CLIInstallerError.bundledBinaryNotFound
    }
    guard FileManager.default.fileExists(atPath: bundledPath) else {
      throw CLIInstallerError.bundledBinaryNotFound
    }

    // Use NSAppleScript to create the symlink with admin privileges.
    let dir = shellEscape(
      URL(filePath: Self.installPath).deletingLastPathComponent().path(percentEncoded: false))
    let dst = shellEscape(Self.installPath)
    let src = shellEscape(bundledPath)
    try runPrivileged(
      "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
      prompt: "Supacode needs administrator access to install the CLI to /usr/local/bin."
    )
  }
```

Uninstall (lines 40-46) — just removes the symlink, privileged, and only if
currently installed:

```swift
  func uninstall() throws {
    guard isInstalled() else { return }
    try runPrivileged(
      "rm -f \(shellEscape(Self.installPath))",
      prompt: "Supacode needs administrator access to uninstall the CLI from /usr/local/bin."
    )
  }
```

The privilege escalation itself (lines 48-71) — **this is the load-bearing
part**:

```swift
  /// Runs a shell command with administrator privileges via `NSAppleScript`.
  ///
  /// Using `NSAppleScript` in-process (instead of shelling out to `/usr/bin/osascript`)
  /// makes macOS show the Supacode icon and name in the authorization dialog.
  private func runPrivileged(_ command: String, prompt: String) throws {
    let escapedCommand = command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
    let escapedPrompt = prompt.replacing("\"", with: "\\\"")
    let source =
      "do shell script \"\(escapedCommand)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else {
      throw CLIInstallerError.installFailed("Failed to prepare authorization script.")
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    guard errorInfo == nil else {
      let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int
      // -128 means the user cancelled the authorization dialog.
      if errorNumber == -128 {
        throw CLIInstallerError.cancelled
      }
      let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? ""
      throw CLIInstallerError.installFailed(message)
    }
  }
}
```

Shell escaping (lines 75-77) — single-quote wrapping to make the constructed
command injection-safe:

```swift
private nonisolated func shellEscape(_ value: String) -> String {
  "'" + value.replacing("'", with: "'\\''") + "'"
}
```

Errors (lines 79-94) — `bundledBinaryNotFound`, `cancelled` (maps the `-128`
user-cancel), `installFailed(String)`. `cancelled.errorDescription` is `nil`
so a user-cancel shows no error banner.

### 2.2 How it's surfaced through the app (TCA-specific, optional)

supacode uses The Composable Architecture, so it wraps `CLIInstaller` in a
dependency client and drives it from a reducer. Batty does not use TCA — you
can call `CLIInstaller` directly from a SwiftUI button action / `@Observable`
model. For reference:

- Dependency client:
  `../supacode/SupacodeSettingsShared/Clients/Settings/CLIInstallerClient.swift`
  — exposes `checkInstalled` / `install` / `uninstall`, with `liveValue`
  hopping the throwing calls onto `MainActor.run { ... }` (lines 20-37).
- Reducer wiring:
  `../supacode/SupacodeSettingsFeature/Reducer/SettingsFeature.swift` — a
  `CLIInstallState` enum (`.checking / .installed / .notInstalled / .installing
  / .uninstalling / .failed(String)`, line 11) and the
  `cliInstallTapped` / `cliUninstallTapped` / `cliInstallCompleted` handlers
  (lines 332-372). The `.failure` handler special-cases `CLIInstallerError
  .cancelled` to revert to the prior state instead of showing an error
  (lines 364-371).
- View:
  `../supacode/supacode/Features/Settings/Views/DeveloperSettingsView.swift`
  — `CLIInstallRow` (lines 76-111) renders Install / Installed+Uninstall /
  Installing… / Uninstalling… based on state, with footer text: *"Symlinks
  `supacode` to `/usr/local/bin`. This is not required to run `supacode` in the
  app terminals."* (line 15).

### 2.3 How the CLI gets into the app bundle (build side)

supacode uses Tuist (`Project.swift`), not a raw `.xcodeproj`, but the moving
parts map directly onto an Xcode project.

**Separate command-line-tool target** —
`../supacode/Project.swift` lines 116-140:

```swift
.target(
  name: "supacode-cli",
  destinations: .macOS,
  product: .commandLineTool,
  bundleId: "app.supabit.supacode.cli",
  deploymentTargets: .macOS("26.0"),
  infoPlist: .default,
  buildableFolders: ["supacode-cli"],
  dependencies: [.external(name: "ArgumentParser")],
  settings: .settings(
    base: [
      "CODE_SIGNING_ALLOWED": "NO",
      "ENABLE_HARDENED_RUNTIME": "YES",
      "PRODUCT_MODULE_NAME": "supacode_cli",
      "PRODUCT_NAME": "supacode",      // the binary is literally named "supacode"
      "SKIP_INSTALL": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    ],
    defaultSettings: .essential
  )
)
```

The CLI source itself is a normal `swift-argument-parser` program —
`../supacode/supacode-cli/SupacodeCLI.swift`:

```swift
import ArgumentParser

@main
struct SupacodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "supacode",
    abstract: "Control Supacode from the command line.",
    subcommands: [ /* OpenCommand, WorktreeCommand, ... */ ],
    defaultSubcommand: OpenCommand.self
  )
}
```

**The app target depends on the CLI target** so it builds first —
`Project.swift` line 41 (`.target(name: "supacode-cli")` in `appDependencies`).

**A post-build "Embed Runtime Assets" script copies the built CLI into the
bundle** — declared at `Project.swift` lines 227-233, with input/output paths
at lines 80-95. The key output is:

```
$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/supacode
```

i.e. `…/supacode.app/Contents/Resources/bin/supacode`.

The script — `../supacode/scripts/embed-runtime-assets.sh` (relevant lines):

```bash
destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
bin_destination_dir="${destination_root}/bin"
cli_candidates=(
  "${BUILT_PRODUCTS_DIR}/supacode"
  "${UNINSTALLED_PRODUCTS_DIR}/${PLATFORM_NAME}/supacode"
)
# pick the first executable candidate -> cli_source
rm -rf "${bin_destination_dir}"
mkdir -p "${bin_destination_dir}"
/bin/cp -f "${cli_source}" "${bin_destination_dir}/supacode"
```

So the chain is:

```
supacode-cli target  ->  builds executable "supacode"
        |  (app target depends on it)
        v
embed-runtime-assets.sh (post-build phase on app target)
        |  /bin/cp into Contents/Resources/bin/supacode
        v
app bundle: Contents/Resources/bin/supacode
        |  (at runtime, user clicks Install)
        v
ln -s  ->  /usr/local/bin/supacode  (privileged via NSAppleScript)
```

---

## 3. Answers to the specific questions

1. **Where does the CLI live in the bundle / what is it?** A *compiled
   Swift executable* (built by the `supacode-cli` command-line-tool target),
   copied to `…/supacode.app/Contents/Resources/bin/supacode`. Not a script,
   not a symlink target inside the bundle.
2. **Install mechanism / how it gets write access to `/usr/local/bin`.**
   `NSAppleScript` running `do shell script "…" with administrator privileges`.
   macOS shows the standard authorization dialog and, because the script runs
   in-process, brands it with the app icon/name. No SMJobBless / Authorization
   C API / XPC helper.
3. **Exact code path.** `CLIInstaller.install()` →
   `CLIInstaller.runPrivileged()` in
   `SupacodeSettingsShared/BusinessLogic/CLIInstaller.swift` (install lines
   21-38, escalation lines 52-71). Triggered from the UI via the TCA client +
   reducer (§2.2).
4. **Admin/sudo prompt?** Yes — a single system authorization dialog
   (password or Touch ID) per install and per uninstall. User-cancel is
   error `-128`, mapped to `.cancelled` and surfaced as *no* error.
5. **Copy or symlink?** **Symlink** from `/usr/local/bin/supacode` into the
   bundle's `Resources/bin/supacode`. **On app move/rename/update to a new
   path**, the symlink still points at the old location: `isInstalled()`
   returns false (target no longer matches the current bundle path) and the
   dangling link must be replaced by re-installing. (Re-install does
   `rm -f` then `ln -s`, so it self-heals.) If the app updates *in place* at
   the same path, the symlink keeps working.
6. **Entitlements / signing / sandbox.** supacode's CLI target sets
   `CODE_SIGNING_ALLOWED = NO` and `SKIP_INSTALL = YES`; the embedded binary
   inherits the app's signature via the normal bundle-signing pass. The app is
   sandboxed-ish but importantly carries
   `com.apple.security.automation.apple-events` in its entitlements
   (`../supacode/supacode/supacode.entitlements`) — that is what lets
   `NSAppleScript`/`do shell script` run. Hardened Runtime is on
   (`ENABLE_HARDENED_RUNTIME = YES`) for notarization.
7. **How the CLI is built.** A *separate command-line-tool target*
   (`product: .commandLineTool`) named so its `PRODUCT_NAME` is `supacode`,
   plus a post-build copy phase on the app target. Not a build phase that
   compiles inline; a real target the app depends on.
8. **Uninstall.** `CLIInstaller.uninstall()` runs `rm -f
   /usr/local/bin/supacode` privileged, guarded by `isInstalled()`. Same auth
   dialog.

---

## 4. Step-by-step: replicate this for `batty`

The CLI target is defined in the **`BattyKit` Swift package** (top goal: keep as
much code as possible in the package). The package *builds* the `batty`
executable and lets it share BattyKit code; the `Batty.xcodeproj` app target
only *embeds and installs* the built binary. The runtime install code is
identical to supacode.

> **Why the package, not a standalone Xcode CLI target:** the CLI needs Batty's
> model layer (`Session`, `Pane`, `Tab`, `SplitNode`, workspace types, any
> app-IPC client), which all live in BattyKit. A package `executableTarget` can
> `import BattyKit` directly with zero duplication, and `swift run batty` keeps
> the package self-contained (consistent with the "BattyKit must stand on its
> own" convention in `CLAUDE.md`). A standalone Xcode CLI target would have to
> link BattyKit as a library to get the same thing — more wiring, less of the
> code in the package.

### 4.1 Define the `batty` executable target in `BattyKit/Package.swift`

Add an `.executable` product and an `.executableTarget` to
`BattyKit/Package.swift`. Reuse the shared `swiftSettings` so the CLI gets the
same Swift 6 / `MainActor` default-isolation / StrictConcurrency settings as the
rest of the package:

```swift
products: [
    .library(name: "BattyKit", targets: ["BattyKit"]),
    .executable(name: "batty", targets: ["batty"]),        // new
],
dependencies: [
    // ...existing deps...
    // Add only if you want subcommands/flag parsing:
    // .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
],
targets: [
    .target(name: "BattyKit", /* ...unchanged... */),
    .executableTarget(                                      // new
        name: "batty",
        dependencies: [
            "BattyKit",                                     // the payoff: share the model layer
            // .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(name: "BattyKitTests", /* ...unchanged... */),
]
```

Sources live at `BattyKit/Sources/batty/`. The entry point can be a simple
`main.swift`, or — if you want subcommands — a `swift-argument-parser` program:

```swift
import ArgumentParser
import BattyKit

@main
struct BattyCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "batty",
    abstract: "Control Batty from the command line."
    // subcommands: [...]
  )
}
```

The product name is `batty`, so SwiftPM/Xcode builds an executable literally
named `batty` into `BUILT_PRODUCTS_DIR` — exactly the path the embed phase in
§4.2 probes.

Notes specific to a package executable:

- **`@main` under `MainActor` default isolation.** Because `swiftSettings`
  applies `.defaultIsolation(MainActor.self)`, the `@main` entry is main-actor
  isolated. That's fine for a CLI; keep async work explicit if you spawn it.
- **Verify it builds from the package:** `cd BattyKit && swift build` (and
  `swift run batty --help`) should produce and run the tool with no Xcode
  involved. This is the litmus test that the code is genuinely package-owned.
- **The workspace must own the package** (per the BattyKit sole-owner rule in
  `CLAUDE.md` / project memory) so the new executable product is visible to the
  app target. Don't re-add a bare `XCLocalSwiftPackageReference`.

### 4.2 Embed the built CLI into the app bundle

Xcode automatically links *library* products an app target depends on, but it
does **not** copy a package's *executable* product into the bundle — so the
package builds `batty`, and the app target embeds it.

First, **make the Batty app target depend on the `batty` executable product** so
it is built before the copy runs (app target ▸ Build Phases ▸ Dependencies, or
the "+" under the package's products). Heads-up: Xcode's handling of a *package
executable product* as an app-target dependency is less trodden than a native
target dependency — after wiring it, confirm a clean app build actually
produces `${BUILT_PRODUCTS_DIR}/batty`. If it won't attach cleanly in your Xcode
version, the fallback is to have the Run Script below invoke the build itself,
but try the dependency route first.

Then add a **Run Script** build phase to the **Batty app target**, ordered
*after* the CLI has built. Script body (adapted from supacode's
`scripts/embed-runtime-assets.sh`):

```bash
set -euo pipefail
dest_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
cli=""
for c in "${BUILT_PRODUCTS_DIR}/batty" \
         "${UNINSTALLED_PRODUCTS_DIR}/${PLATFORM_NAME}/batty"; do
  [ -x "$c" ] && cli="$c" && break
done
[ -n "$cli" ] || { echo "error: missing built batty executable" >&2; exit 1; }
rm -rf "$dest_dir"
mkdir -p "$dest_dir"
/bin/cp -f "$cli" "$dest_dir/batty"
```

Declare its **output file** as
`$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/batty` so Xcode
tracks it and re-signs it. (supacode declared input/output paths and used
`basedOnDependencyAnalysis: false` to always run.)

Per Batty's `CLAUDE.md`, `scripts/` is a restricted area — if you put the embed
logic in a script there, get user confirmation; an inline Run Script phase on
the app target avoids touching `scripts/`.

Result: `Batty.app/Contents/Resources/bin/batty`.

### 4.3 Add the installer (Swift)

Put `CLIInstaller.swift` in **BattyKit** (keep-code-in-the-package goal); the
Settings UI in the app target calls it. It only touches `Bundle.main`,
`FileManager`, and `NSAppleScript`, so it has no app-target dependencies and
belongs in the package. This is essentially a verbatim port of supacode's —
rename `supacode → batty`:

```swift
import Foundation

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

    let dir = shellEscape(URL(filePath: Self.installPath)
      .deletingLastPathComponent().path(percentEncoded: false))
    let dst = shellEscape(Self.installPath)
    let src = shellEscape(bundledPath)
    try runPrivileged(
      "mkdir -p \(dir) && rm -f \(dst) && ln -s \(src) \(dst)",
      prompt: "Batty needs administrator access to install the CLI to /usr/local/bin.")
  }

  func uninstall() throws {
    guard isInstalled() else { return }
    try runPrivileged(
      "rm -f \(shellEscape(Self.installPath))",
      prompt: "Batty needs administrator access to uninstall the CLI from /usr/local/bin.")
  }

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

private nonisolated func shellEscape(_ value: String) -> String {
  "'" + value.replacing("'", with: "'\\''") + "'"
}

enum CLIInstallerError: Error, LocalizedError, Equatable {
  case bundledBinaryNotFound, cancelled, installFailed(String)
  var errorDescription: String? {
    switch self {
    case .bundledBinaryNotFound: "The CLI binary was not found in the app bundle."
    case .cancelled: nil
    case .installFailed(let r): r.isEmpty ? "Installation failed." : r
    }
  }
}
```

Batty conventions: this file needs no header comment beyond `// CLIInstaller.swift`,
and if it logs anything add a file-scoped
`nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "CLIInstaller")`.
`NSAppleScript` is main-thread-only, so call `install()/uninstall()` from the
main actor (they're trivial and blocking-on-the-dialog anyway).

### 4.4 Surface it in Settings

Add a row to Batty's Settings (an "Advanced"/"Developer"-style pane) with an
Install / Uninstall button driven by an `@Observable` model that holds a small
state enum and calls `CLIInstaller`. On appear, call `isInstalled()` to set the
initial state. Treat `CLIInstallerError.cancelled` as a no-op (revert to prior
state, no error banner). This is per-user UI work, so mark the issue `resolved`
not `closed` and note in `## Gotchas` that you couldn't visually verify the auth
dialog branding without a signed build.

### 4.5 Entitlements

Batty is **unsandboxed** (`ENABLE_APP_SANDBOX = NO`), which makes this strictly
*easier* than supacode — an unsandboxed process can run `do shell script` and
write/symlink freely (subject to the `/usr/local/bin` permission, which is what
the admin auth covers). Specifically:

- You **do not** need the App Sandbox `com.apple.security.automation.apple-events`
  entitlement for `NSAppleScript` here, because supacode needed it only to
  satisfy the *sandbox*. Unsandboxed, `do shell script ... with administrator
  privileges` works without it.
- **Hardened Runtime stays ON** for notarization (Batty already requires this).
  `do shell script` is fine under Hardened Runtime — it spawns `/bin/sh` as a
  *separate* privileged process via the Security authorization plugin; it does
  not inject code into the app, so no `disable-library-validation` or
  `allow-unsigned-executable-memory` exception is needed.
- The embedded `batty` binary must be **signed and notarized as part of the
  app** (it ships in `Contents/Resources/bin/`). The normal app signing pass
  covers it as long as the Run Script phase declared its output path.

---

## 5. Gotchas

- **Privilege escalation is per-action, interactive.** Each install/uninstall
  pops one auth dialog. There's no way to make it silent, and you shouldn't try
  — that's the user's consent. Don't auto-install on launch.
- **User-cancel is error `-128`**, not a failure. Map it to a dedicated
  `.cancelled` case and show nothing.
- **Symlink, not copy → app moves break it.** Because `/usr/local/bin/batty`
  points *into the bundle*, if the user moves Batty.app (e.g. Downloads →
  Applications) or a Sparkle/auto-update relocates it, the symlink dangles and
  `isInstalled()` reports false. The fix is to re-install (the Settings row
  should show "Install" again). Consider checking `isInstalled()` on app
  foreground and nudging the user if it's gone stale. A *copy* would survive
  moves but then goes stale on every app update (old binary) and needs its own
  refresh logic — supacode chose symlink so the CLI always matches the
  installed app.
- **`NSAppleScript` must run on the main thread.** Don't call `runPrivileged`
  off-main.
- **Shell-injection safety.** Keep the `shellEscape` single-quote wrapping for
  every interpolated path. Bundle paths can contain spaces/quotes
  (`/Users/Jane's Mac/...`).
- **`/usr/local/bin` may not exist** on a clean macOS (it's created by
  Homebrew). The `mkdir -p` in the install command handles that — keep it.
- **PATH.** `/usr/local/bin` is on the default macOS PATH for interactive
  shells, so no PATH editing is needed. This is the main reason to prefer it
  over `~/.local/bin` (see alternatives).
- **CLI ↔ app communication.** supacode's CLI talks to the running app over a
  local socket (note the `SocketCommand`/`bin/zmx` machinery). If `batty`'s CLI
  needs to drive the running app (open sessions, etc.), design that IPC
  separately — it's orthogonal to *installation*.
- **Don't run notarization/release autonomously** (Batty rule). The embedded
  CLI only ships correctly through the normal `scripts/release.sh` pipeline,
  which the user runs.

---

## 6. Alternatives worth noting

- **Symlink vs copy** (covered above): supacode symlinks so the CLI tracks the
  installed app version; the cost is fragility on app moves. A copy is robust
  to moves but stale on updates. For a versioned, frequently-updated app the
  symlink is the better default.
- **`/usr/local/bin` vs `~/.local/bin`.** Installing to `~/.local/bin` (or
  `~/bin`) needs **no admin prompt at all** — it's user-writable. The downside:
  it is *not* on the default macOS PATH, so you'd have to either instruct the
  user to add it or edit their shell rc (`~/.zshrc`), which is invasive and
  brittle across shells. supacode accepted the one-time admin prompt to land on
  a directory that's already on PATH. For Batty, `/usr/local/bin` + a single
  auth dialog is the recommended path; offer `~/.local/bin` only as a
  no-admin fallback if you want one.
- **`SMAppService` / `SMJobBless` privileged helper.** Overkill here. Those are
  for *persistent* privileged daemons. Creating one symlink does not justify a
  bundled, signed, requirement-matched helper tool and its maintenance burden.
  supacode deliberately did **not** use this.
- **Shelling out to `/usr/bin/osascript`** instead of in-process
  `NSAppleScript`: works, but the auth dialog is then branded as
  *osascript / Script Editor* rather than your app. In-process `NSAppleScript`
  is what gives the dialog the Batty icon and name — keep it in-process.
- **Package `executableTarget` vs standalone Xcode command-line-tool target.**
  supacode used a standalone Tuist `commandLineTool` target. Batty uses a
  package `executableTarget` (§4.1) because the top code-management goal is to
  keep as much as possible in BattyKit, and the CLI needs BattyKit's model
  layer. The cost is that Xcode won't auto-embed a *package executable product*
  into the bundle — you add the app→executable dependency and the copy phase
  yourself (§4.2). A standalone Xcode target embeds slightly more turnkey but
  would either duplicate the model code or link BattyKit anyway; given the
  keep-it-in-the-package goal, the package target wins.

---

## References

For Batty, the CLI target is defined in `BattyKit/Package.swift` as an
`executableTarget` (sources under `BattyKit/Sources/batty/`), not as a separate
Xcode target. The supacode references below show the *standalone-target* variant
Batty deliberately diverges from — they remain the canonical source for the
install/escalation code, which Batty ports verbatim.

In `../supacode`:

- `SupacodeSettingsShared/BusinessLogic/CLIInstaller.swift` — the installer
  (install/uninstall/runPrivileged).
- `SupacodeSettingsShared/Clients/Settings/CLIInstallerClient.swift` — TCA
  dependency wrapper (Batty can skip).
- `SupacodeSettingsFeature/Reducer/SettingsFeature.swift` — install state +
  reducer handlers (lines ~11, 332-372).
- `supacode/Features/Settings/Views/DeveloperSettingsView.swift` — the Settings
  UI row (lines 76-111, footer line 15).
- `Project.swift` — CLI target (lines 116-140), app dependency (line 41),
  embed post-build phase (lines 80-95, 227-233).
- `scripts/embed-runtime-assets.sh` — copies the built CLI into
  `Contents/Resources/bin/`.
- `supacode-cli/SupacodeCLI.swift` — the CLI program entry point.
- `supacode/supacode.entitlements` — `apple-events` entitlement (needed only
  because supacode is sandboxed; Batty, unsandboxed, does not need it).
