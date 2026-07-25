# Shipping a CLI inside your app and installing it to `/usr/local/bin`

> **Vendored copy — not a Batty document.** Copied 2026-07-24 from
> `RemoteControl/docs/cli-embedding-and-install.md` (a sibling, throwaway,
> read-only checkout at `/Users/brennan/Developer/brennanMKE/RemoteControl`)
> for Batty issue [#0267](../../issues/0267.md). It describes the
> RemoteControl XPC prototype — a different app — not Batty; the
> "must rename" / "copy verbatim" markers throughout are written for that
> porting exercise. The body below is unedited from the source.
>
> **Any bare `#NNNN` below is a RemoteControl issue** (that project's own
> `issues/0001`–`issues/0031` tracker), never a Batty issue — Batty's
> tracker uses the identical `#NNNN` form for a disjoint set of numbers.
> Links to files this vendoring did not copy (RemoteControl's `issues/`
> folder, its repo-root `README.md`) will not resolve; see the source
> checkout above if it still exists.

Building the tool in a Swift package, embedding it in the app bundle, signing it
so the bundle seal holds, and letting the user install it from a File-menu
action.

Rename as you go: `yourctl` for the binary, `YourKit` for the package,
`YourApp` for the app.

## The chain

```
package executableTarget "yourctl"
        │  Run Script phase: xcrun swift build --product yourctl
        ▼
YourApp.app/Contents/Resources/bin/yourctl        (embedded, signed)
        │  File ▸ Install Command Line Tool…  (NSAppleScript, admin)
        ▼
/usr/local/bin/yourctl  ──symlink──▶  back into the bundle
```

Four decisions, each with a reason that only shows up later.

## 1. Define the CLI in the Swift package

```swift
products: [
    .library(name: "YourKit", targets: ["YourKit"]),
    // NOT added as an Xcode package product dependency -- see step 2.
    .executable(name: "yourctl", targets: ["yourctl"]),
],
targets: [
    .target(name: "YourKit"),
    .executableTarget(
        name: "yourctl",
        dependencies: [
            "YourKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(name: "YourKitTests", dependencies: ["YourKit"]),
]
```

Sources at `YourKit/Sources/yourctl/`. The product name becomes the binary name,
so name it what the user will type.

**Why the package rather than a standalone Xcode command-line-tool target:** the
CLI needs the shared XPC contract — the protocols, the message types, the
service names. Those live in the package. A package `executableTarget` can
`import YourKit` with zero duplication, and `swift run yourctl --help` works with
no Xcode involved, which is a genuinely useful property when debugging.

**Keep the CLI's dependency surface minimal, and check it.** A sibling project
hit this hard: its CLI depended on the whole app library, which linked a
framework, so the CLI inherited an `@rpath/Something.framework` load command.
From `Contents/Resources/bin/` — two levels below `Contents/Frameworks/` — no
baked-in rpath can reach it, so the embedded binary crashed at launch with
`Library not loaded`. It worked fine when run from the SwiftPM build directory,
whose rpath happens to include the built framework, so the bug shipped.

The fix there was splitting a dependency-free core target out of the library and
pointing the CLI at only that. Whether you need to split depends on what your
library links. **The check is cheap and belongs in your release script:**

```bash
otool -L "$APP/Contents/Resources/bin/yourctl" | grep @rpath   # expect nothing
```

A healthy CLI here is ~1.9 MB with no `@rpath` lines — only `libSystem`,
`Foundation`, and the `/usr/lib/swift` dylibs. If the binary balloons or an
`@rpath` appears, it got re-coupled to something with a framework.

## 2. Embed it with a Run Script phase — never a product dependency

> **Do not add the CLI's executable *product* as an Xcode
> `XCSwiftPackageProductDependency` on the app target.**

This is the one that will cost you a day. Wiring a package *executable* product
as an app-target dependency pulls it into the scheme's build graph, and once it
is there the `xcodebuild` test runner can no longer resolve the library's
`Bundle.module` resource bundle. Every test in that bundle then crashes on
launch:

```
resource_bundle_accessor.swift: Fatal error: unable to find bundle named YourKit_YourKit
** TEST FAILED **
```

`swift test` does **not** reproduce it — only the Xcode test runner does — so it
is easy to introduce and hard to attribute. (Recorded in the sibling project as
a regression that broke a 372-test gate and had to be fully reverted.)

Instead, add a **Run Script** phase on the app target that builds the CLI from
the package. The executable never enters Xcode's graph:

```bash
set -euo pipefail

# SwiftUI preview builds re-run script phases; nothing here is needed for one.
if [ "${ENABLE_PREVIEWS:-NO}" = "YES" ] && [ -n "${PREVIEW_FRAMEWORK_PATHS:-}" ]; then
    echo "note: skipping CLI embed for preview build"
    exit 0
fi

PACKAGE_DIR="$SRCROOT/YourKit"

case "$CONFIGURATION" in
    Release) SWIFT_CONFIG=release ;;
    *)       SWIFT_CONFIG=debug ;;
esac

# One --arch per Xcode arch, so a universal app gets a universal CLI.
ARCH_FLAGS=""
for arch in $ARCHS; do
    ARCH_FLAGS="$ARCH_FLAGS --arch $arch"
done

# Scratch path under DERIVED_FILE_DIR rather than the package's .build, so an
# Xcode build does not fight a `swift build` running in a terminal.
SCRATCH="$DERIVED_FILE_DIR/yourkit"

BUILD_ARGS="--package-path $PACKAGE_DIR --scratch-path $SCRATCH \
            --configuration $SWIFT_CONFIG $ARCH_FLAGS --product yourctl"

xcrun swift build $BUILD_ARGS
BIN_DIR="$(xcrun swift build $BUILD_ARGS --show-bin-path)"

DEST_DIR="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/bin"
mkdir -p "$DEST_DIR"
cp -f "$BIN_DIR/yourctl" "$DEST_DIR/yourctl"
```

Declare the **output path** so Xcode tracks the file:

```
$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/bin/yourctl
```

Three details in that script are worth keeping:

- **`--show-bin-path` with the identical arguments.** SwiftPM's output directory
  depends on configuration and arch flags; asking it rather than constructing the
  path is what keeps Debug, Release, and universal builds all working.
- **Scratch path outside the package.** Sharing `.build/` between Xcode and a
  terminal `swift build` means they invalidate each other's work at random.
- **Preview skip.** Script phases re-run for previews and this one is pure
  overhead there.

## 3. Sign the embedded binary yourself

> **Xcode does not sign a Mach-O that a script phase drops into the bundle**, and
> an unsigned nested binary breaks the bundle seal.

Append to the same script:

```bash
if [ "${CODE_SIGNING_REQUIRED:-YES}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --options runtime --timestamp=none "$DEST_DIR/yourctl"
else
    echo "note: code signing disabled; embedded CLI left unsigned"
fi
```

The `CODE_SIGNING_REQUIRED` guard matters: you want unsigned builds
(`CODE_SIGNING_ALLOWED=NO`) to keep working for ordinary compile checks — see
[build-and-release.md](build-and-release.md) for why that is not optional.

### The verification trap

A binary under `Contents/Resources/` is sealed as a **resource**, not as nested
code. So:

```bash
codesign -v --deep --strict "$APP"       # passes, never mentions the CLI
```

`--deep` descends into nested *code* — frameworks, helpers in
`Contents/MacOS/`, XPC services. It does not descend into resources. Your
embedded CLI can be entirely unsigned and `--deep --strict` will still report
the bundle valid. **Check it separately:**

```bash
codesign -v "$APP/Contents/Resources/bin/yourctl"
```

And then, because signature validity is not the same as *runnability*, **actually
execute it**:

```bash
"$APP/Contents/Resources/bin/yourctl" --version
```

This is the check whose absence let the `@rpath` crash from step 1 ship in the
sibling project. Its verification ran `swift run` and checked the embedded copy
with `file` — architecture only. Running the embedded binary would have caught it
in one second.

### Report a real version

Read it from the host app's `Info.plist` rather than hardcoding a string that
drifts:

```swift
func resolveAppVersion() -> String {
    // Resolve symlinks FIRST: the installed entry point is
    // /usr/local/bin/yourctl, a link into the bundle. Without this the walk
    // upward lands in /usr/local and finds no plist.
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    else { return "unknown" }

    let contents = executable            // …/Contents/Resources/bin/yourctl
        .deletingLastPathComponent()     // …/Contents/Resources/bin
        .deletingLastPathComponent()     // …/Contents/Resources
        .deletingLastPathComponent()     // …/Contents
    let plist = contents.appending(path: "Info.plist", directoryHint: .notDirectory)

    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
          let short = info["CFBundleShortVersionString"] as? String
    else { return "unknown" }

    if let build = info["CFBundleVersion"] as? String, build != short {
        return "\(short) (\(build))"
    }
    return short
}
```

`"unknown"` outside a bundle is the honest answer, and it is what you get running
from the SwiftPM build directory.

## 4. The installer

Put it in the **package**, not the app target. It touches only `Bundle`,
`FileManager`, and `NSAppleScript` — all available to a package targeting macOS,
and `NSAppleScript` is Foundation, so this costs no AppKit dependency.

More importantly: **present no UI from it.** Return a value the app renders. That
is what makes the state machine testable, and the state machine is where the
bugs are.

### Symlink, not copy

`/usr/local/bin/yourctl` is a symlink *into the bundle*. Consequences:

- The CLI always matches the installed app. No staleness after an app update.
- Moving or renaming the app makes the link dangle and the install read as
  not-installed. Re-installing self-heals.

A copy survives moves but goes stale on every update and needs its own refresh
logic. The symlink is the better default for anything versioned.

### Four states, not a boolean

The obvious API is `isInstalled() -> Bool` comparing the symlink target to the
current bundle path. It is not enough. Distinguish:

```swift
public enum State: Equatable, Sendable {
    case notInstalled                 // nothing at the destination
    case installedHere                // a link into *this* bundle
    case installedElsewhere(String)   // a link somewhere else — carries where
    case blockedByFile                // not a symlink; never clobber it
}
```

`installedElsewhere` lets the UI say *which* copy is winning, which is the
difference between "install seems broken" and "you have two copies of the app".
`blockedByFile` means you never destroy a real binary the user put there.

The inspection has one subtlety that a boolean gets wrong:

```swift
public static func inspect(_ path: URL, expecting target: URL) -> State {
    let fm = FileManager.default
    // attributesOfItem does NOT follow symlinks, which is what makes it usable
    // for telling a link apart from a real file. fileExists(atPath:) DOES
    // follow, so it reports false for a dangling link -- exactly the state left
    // behind when the target app is deleted, and it would read as "nothing
    // installed" while a broken command sat on PATH.
    guard let attributes = try? fm.attributesOfItem(atPath: path.path) else {
        return .notInstalled
    }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
        return .blockedByFile
    }
    guard let resolved = try? fm.destinationOfSymbolicLink(atPath: path.path) else {
        return .notInstalled
    }
    return resolved == target.path ? .installedHere : .installedElsewhere(resolved)
}
```

### Refuse to install from a build directory

The case that matters in daily development: you launch from Xcode, click
Install, and get a symlink into DerivedData that breaks on the next clean build.
The failure surfaces days later as `yourctl: command not found`, with nothing
connecting it to the cause.

```swift
public var isBundleDurable: Bool {
    let path = bundleURL.path
    return !path.contains("/DerivedData/") && !path.contains("/Build/Products/")
}
```

Declining with an explanation is strictly better than silently creating a doomed
link. Say where the bundle is and tell the user to move the app to Applications
first.

### `PATH` shadowing

If a link exists in a directory earlier on `PATH` than your destination, it wins,
and a correct install looks like it did nothing. This bit us: an earlier version
installed to `~/.local/bin`, which on this machine precedes `/usr/local/bin`.
After switching destinations, the old link silently kept answering.

Sweep it on install, but only if it is *yours*:

```swift
private var shadowingLegacyLink: URL? {
    switch Self.inspect(legacyDestination, expecting: bundledCLI) {
    case .installedHere:
        return legacyDestination
    case .installedElsewhere(let target) where target.contains("/YourApp.app/"):
        // Points at another copy of our app -- still ours, still shadows.
        return legacyDestination
    default:
        return nil                       // somebody else's tool; leave it
    }
}
```

More generally: prefer `/usr/local/bin`. It is on the default macOS `PATH`, which
is the whole reason to accept an admin prompt. `~/.local/bin` needs no
privileges but is *not* on the default `PATH`, so you would have to edit the
user's shell rc — invasive, shell-specific, and brittle. One authentication
dialog is the better trade.

### Privilege escalation

`/usr/local/bin` is `root:wheel` on a stock macOS install. Escalate with
`NSAppleScript`, in-process:

```swift
private func runPrivileged(_ command: String, reason: String) throws {
    let escaped = appleScriptQuoted(command)
    let escapedReason = appleScriptQuoted(reason)
    let source = "do shell script \"\(escaped)\" "
        + "with prompt \"\(escapedReason)\" with administrator privileges"

    guard let script = NSAppleScript(source: source) else {
        throw CLIInstallerError.scriptUnavailable
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)

    if let errorInfo {
        let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        // -128 is userCanceledErr: the standard "user hit Cancel" code.
        if code == -128 { throw CancellationError() }
        let message = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "AppleScript error \(code)"
        throw CLIInstallerError.privilegedCommandFailed(message)
    }
}
```

Five things to get right:

**In-process, not `osascript`.** Shelling out to `/usr/bin/osascript` works, but
the authorization dialog is then branded *Script Editor*. In-process
`NSAppleScript` gets your app's icon and name.

**Pass `with prompt`.** Omit it and the dialog asks for a password while
explaining nothing. This project shipped without it — the reason string was
computed and logged but never reached the dialog, so the user saw a bare
credential request for an unexplained change. It is one parameter and it is the
difference between a comprehensible prompt and a suspicious one.

**`-128` is user-cancel, not failure.** Map it to a dedicated case and show
nothing. An error banner after someone deliberately hit Cancel is noise.

**Single-quote-wrap every interpolated path.** Bundle paths contain spaces and
can contain quotes (`/Users/Jane's Mac/…`):

```swift
static func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

This is a shell-injection boundary, so give it tests. The interesting case is
the embedded single quote, which would otherwise close the string early and let
the remainder run as shell.

**Keep `mkdir -p`.** `/usr/local/bin` does not exist on a clean macOS — it is
created by Homebrew. And use `ln -sfn` rather than `rm -f && ln -s`: one atomic
replacement, no window where nothing is on `PATH`, and `-n` stops it
dereferencing a link-to-directory.

```swift
try runPrivileged(
    "mkdir -p \(shellQuoted(destinationDirectory.path)) && "
        + "ln -sfn \(shellQuoted(bundledCLI.path)) \(shellQuoted(destination.path))",
    reason: "YourApp needs administrator access to create a symlink in /usr/local/bin."
)
```

**`NSAppleScript` must run on the main thread.** It is `@MainActor`-friendly and
blocks synchronously through the dialog. A consequence: any "Installing…"
spinner you add will never render. Don't bother with one.

**No `SMJobBless`.** Privileged helpers exist for persistent privileged daemons.
Creating one symlink does not justify a bundled, signed, requirement-matched
helper tool and its maintenance burden.

### Return reports, don't present alerts

```swift
public struct Report: Equatable, Sendable {
    public enum Severity: Equatable, Sendable { case informational, warning }
    public let severity: Severity
    public let title: String
    public let detail: String
}

@discardableResult public func install() -> Report? { … }
```

`nil` means deliberately nothing to say — the auth dialog was cancelled, or there
was nothing to remove. The app translates:

```swift
@MainActor
enum CLIInstallActions {
    static func install(_ cli: CLIInstaller) {
        cli.refresh()
        present(cli.install())
    }

    private static func present(_ report: CLIInstaller.Report?) {
        guard let report else { return }
        let alert = NSAlert()
        alert.alertStyle = report.severity == .warning ? .warning : .informational
        alert.messageText = report.title
        alert.informativeText = report.detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

For logging, inject a closure rather than depending on the app's log type:

```swift
public init(
    bundle: URL = Bundle.main.bundleURL,
    destinationDirectory: URL = URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
    legacyDestination: URL = …,
    log: @escaping (String, LogLevel) -> Void = { _, _ in }
)
```

Those injected paths are also what make it testable: a test stages a temporary
directory tree and the whole machine operates on it — no `/usr/local/bin`, no
app, no authentication dialog. Twenty tests over the four states, refusal
behaviour, shadow sweeping, and quoting run in 0.02 s.

## 5. The File-menu action

This is where the user actually finds it. Xcode puts its own CLI installer in a
menu, and a File-menu item is more discoverable than a Settings pane the user has
to go looking through.

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("Install Command Line Tool…") {
            CLIInstallActions.install(delegate.cli)
        }
        .disabled(delegate.cli.isInstalledFromThisBundle)

        Button("Uninstall Command Line Tool") {
            CLIInstallActions.uninstall(delegate.cli)
        }
        .disabled(delegate.cli.state == .notInstalled)
    }
}
```

**`CommandGroup(replacing: .newItem)`** is the right anchor. A document-less app
has a "New" item it does not want; replacing that group puts your items at the
top of the File menu and removes the useless one in the same stroke.

**Show both items always, disabling the inapplicable one.** The alternative — one
item whose title swaps between Install and Uninstall — depends on observable
state resolving correctly at menu-build time, which is the fiddlier path in
SwiftUI, and it hides what the app can do. Two greyed-out-when-irrelevant items
make the available actions plain.

**The ellipsis on "Install…" is correct** by Apple's convention: the action opens
a dialog (the authorization prompt) before completing. Uninstall gets none.

**Call `refresh()` before acting.** State can change outside the app — someone
deleted the link, or installed a different copy. Refreshing at the moment of the
click costs one `stat`.

## Uninstall

Privileged `rm -f`, guarded by state:

```swift
if case .blockedByFile = state {
    return Report(severity: .warning,
                  title: "Nothing was removed.",
                  detail: "\(destination.path) is a regular file, not a symlink this app created.")
}
```

Never remove something you did not create. And sweep the legacy shadow location
here too, so uninstall genuinely leaves nothing behind.

## Checklist

- [ ] `executableTarget` in the package; `swift run yourctl --help` works with no Xcode
- [ ] `otool -L` on the built binary shows no `@rpath` framework loads
- [ ] Run Script phase builds from the package; executable **not** an Xcode product dependency
- [ ] Output path declared on the phase
- [ ] Script signs the embedded binary, guarded on `CODE_SIGNING_REQUIRED`
- [ ] Release verification signs *and executes* the embedded copy, and checks it separately from `--deep`
- [ ] `--version` reads the host `Info.plist`, resolving symlinks first
- [ ] Installer in the package, returning reports, presenting nothing
- [ ] Four states, including the dangling-link case
- [ ] Declines to install from a build directory
- [ ] `with prompt` passed; `-128` treated as cancel; paths single-quote-wrapped
- [ ] `mkdir -p` and `ln -sfn`
- [ ] File-menu items via `CommandGroup(replacing: .newItem)`, both present, inapplicable one disabled
- [ ] Tests over the state machine and the quoting
