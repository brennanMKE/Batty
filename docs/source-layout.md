# BattyKit source layout

`BattyKit/Sources/BattyKit/` groups files by concern. New code lands in
the folder that matches what it does — not at the package root. SPM
treats every `.swift` file under the target root as part of the target
regardless of depth, so subfolders are organizational only and require
no `Package.swift` change.

## Folders

| Folder | Holds | Examples |
|---|---|---|
| `Views/` | SwiftUI views and view-level UI surfaces | `RootWindowView`, `SessionSidebarView`, `PaneView`, `BellFeedView`, `SettingsView`, `AboutPanel`, `TerminalHostView` |
| `Runtime/` | Long-lived stores, runtimes, and registries that own mutable state | `AppStateStore`, `SessionRuntime`, `PaneRuntime`, `TabRuntime`, `BellFeedStore`, `SurfaceRegistry` |
| `Model/` | Pure value types — `Codable`, `Sendable`, no view or libghostty types embedded | `LayoutModel`, `SplitTree`, `SessionNameCache` |
| `Commands/` | Menu commands, keyboard shortcuts, focus plumbing, command-level state | `BattyCommands`, `BattyShortcuts`, `FocusedValues`, `PaneFocus`, `TerminalSurfaceFocuser` |
| `Theme/` | Theme model and preference | `Theme`, `ThemePreference` |
| `Settings/` | Settings-window preference types | `SettingsPreferences` |
| `Updater/` | Sparkle updater wiring | `UpdaterController` |
| `Util/` | Cross-cutting helpers with no better home | `Logging`, `ShellQuote`, `TabTitleFormatter`, `TUIAppRegistry`, `TerminalHostInstaller` |

## Root entries

These stay at the package root and should not be folded into the
groupings above:

- `BattyKit.swift` — module entry / umbrella file.
- `Resources/` — declared in `Package.swift` as `resources: [.process("Resources")]`. The path is load-bearing.
- `ProjectName/` — pre-existing organized subdirectory.
- `Shortcuts/` — pre-existing organized subdirectory.

## Conventions

- Folder names are **PascalCase** to match Swift/Xcode conventions.
- Files keep their existing names. Only the parent directory changes
  when moving a file between groups.
- If a file's concern is genuinely ambiguous, prefer `Util/`. If a new
  concern emerges that doesn't fit any folder, add a new PascalCase
  folder and update this table in the same commit.
