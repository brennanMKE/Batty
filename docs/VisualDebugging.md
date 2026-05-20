# Visual Debugging

Two scripts at the repo root support iterative visual inspection of the Beta build without opening Xcode.

## Scripts

### `build.sh`

Wraps `xcodebuild` for the `Batty (Beta)` scheme. Accepts one or more actions as arguments; defaults to `build`.

| Action | What it does |
|---|---|
| `build` | Builds the `Batty (Beta)` scheme into `./build/` |
| `run` | Builds, then opens `Batty Beta.app` |
| `terminate` | Kills the running `Batty Beta` process |
| `clean` | Cleans the build |
| `screenshot` | Runs `clean build run`, waits 2 s for the window to appear, captures a screenshot, then terminates |

Multiple actions can be chained in a single call and run in sequence:

```sh
./build.sh clean build
./build.sh build run
```

### `screenshot.sh`

Captures the frontmost `Batty Beta` window to a timestamped PNG in `screenshots/`. Depends on the `windows` utility (`~/bin/windows`) which lists all open windows by window ID, PID, bundle ID, app name, and window title. `screenshot.sh` greps that list for `co.sstools.Batty.beta`, takes the first match, and passes the window ID to `screencapture -l`.

The `screenshots/` folder is not tracked in git — add it to `.gitignore` if you want to keep it local.

## Typical workflow

Before running the scripts, set the active environment to Beta:

```sh
./scripts/set-environment.sh Beta
```

Then use whichever combination you need:

**Quick screenshot of the current state (app already running):**
```sh
./screenshot.sh
```

**Full clean-build-screenshot cycle:**
```sh
./build.sh screenshot
```

**Iterating on UI without rebuilding each time:**
```sh
./build.sh run        # launch once
./screenshot.sh       # capture after each change you want to inspect
./build.sh terminate  # quit when done
```

**Rebuild and relaunch:**
```sh
./build.sh terminate build run
```

## How `screenshot` action works

The `screenshot` action in `build.sh` calls the following steps internally:

1. `clean` — removes stale build artifacts
2. `build` — compiles a fresh `Batty Beta.app` into `./build/`
3. `run` — opens the app
4. `sleep 2` — waits for the window to become visible
5. `./screenshot.sh` — captures the window
6. `terminate` — quits the app

If the 2-second wait is too short (e.g. on a slow build machine or if ghostty surfaces take longer to initialise), increase the `sleep` value in `build.sh` directly.

## Prerequisites

- `~/bin/windows` must be on `$PATH`. This is a local utility that queries the window server for the list of open windows.
- Screen Recording permission must be granted to Terminal (or whichever process runs the script) in **System Settings → Privacy & Security → Screen Recording**.
- The Beta build must use bundle ID `co.sstools.Batty.beta` — set by `Configuration/Beta.xcconfig` and activated via `./scripts/set-environment.sh Beta` before building.
