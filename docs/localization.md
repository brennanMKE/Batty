# Localization

Batty ships its user-facing strings through a single Xcode 15+ **String Catalog**:

```
Batty/Localizable.xcstrings
```

Both the app target (`Batty/`) and the framework target (`BattyKit/`) look up
keys in this one catalog. `Bundle.main` is the resolution bundle for SwiftUI's
`LocalizedStringKey` and for `String(localized:)` call sites, so the catalog
that lives in the app bundle wins for every call from either target.

## How the source uses the catalog

- **SwiftUI views** rely on `LocalizedStringKey` auto-extraction. Plain literals
  in `Text("…")`, `Button("…")`, `Label("…", systemImage: …)`, `Toggle("…", …)`,
  `Picker("…", …)`, `Section("…")`, `Stepper("…")`, `TextField("…", …)` and
  `.help("…")` are all picked up by Xcode at build time and merged into
  `Localizable.xcstrings`.
- **Non-View code** uses `String(localized: "…")` (or `String(localized: "…",
  defaultValue: "…", comment: "…")` when a stable symbolic key is preferable).
  These call sites also feed the catalog on build.
- **Verbatim strings** that must *never* translate (the product name `"Batty"`,
  built path segments, etc.) use `Text(verbatim: …)` or a plain `String`
  variable. The catalog still lists `"Batty"` so translators see the canonical
  value but the source skips the lookup.
- **Plurals** live in the catalog as plural variations on the same key (see
  `Paste %lld lines?`, `There %lld open terminal(s).`,
  `%lld unseen bell event(s)`). The English `one`/`other` forms ship in the
  catalog; every translator language adds the variants its language needs.

## Adding a new language

1. Open `Batty.xcodeproj`. Select the project, then **Info → Localizations →
   `+`**. Add the locale (e.g. `fr`, `es`, `ja`).
2. Open `Batty/Localizable.xcstrings`. The new locale column appears for every
   key. Fill them in (or hand the file to a translator).
3. Build the app and switch the macOS system language (or scheme argument
   `-AppleLanguages '(fr)'`) to verify.

## Export / import for translators

Xcode supports a round-trippable XLIFF flow that does not require giving the
translator the whole Xcode project:

```bash
# Export every supported locale to disk. Produces dist/loc/<locale>.xcloc
# bundles, each containing an .xliff file the translator edits.
xcodebuild -exportLocalizations \
  -project Batty.xcodeproj \
  -localizationPath dist/loc

# Export a single language:
xcodebuild -exportLocalizations \
  -project Batty.xcodeproj \
  -localizationPath dist/loc \
  -exportLanguage fr

# After the translator returns edited .xcloc bundles, fold them back in:
xcodebuild -importLocalizations \
  -project Batty.xcodeproj \
  -localizationPath dist/loc/fr.xcloc
```

The import step rewrites `Localizable.xcstrings` with the translator's edits.
Diff the catalog after import — only the `localizations` blocks for the
imported locale should change.

## Smoke test

A small stub `de` translation ships with the catalog for `Quit Batty?`,
`Quit`, and `Cancel`. It exists solely so the build proves the catalog
drives the UI, and so the per-language subagents (issues `#0108`–`#0121`)
have a working reference for how each entry should look. To verify the
round-trip:

```bash
# 1. Build the app:
xcodebuild -scheme Batty -destination 'platform=macOS' build

# 2. Run with the German locale forced on:
open /path/to/Batty.app --args -AppleLanguages '(de)' -AppleLocale de_DE

# 3. Trigger File → Quit (Cmd-Q) while a terminal is open. The alert title
#    reads "Batty beenden?" and the buttons read "Beenden" / "Abbrechen".
```

Once a real `de` translation lands as part of `#0114`, replace the stub with
the full set.

## Conventions

- **Keys are the English source string** (the SwiftUI convention), not symbolic
  keys like `paste.confirmation.title`. Two exceptions: `about.credits.body`
  uses a symbolic key because its English value is a multi-line block, and the
  `Batty` brand key is marked with `extractionState: manual` so it survives
  catalog cleanup runs.
- **Don't translate the product name "Batty"** — call sites use `Text(verbatim:
  "Batty")`, a plain `String` variable, or `Text(verbatim:)` around a runtime
  string that may include the brand.
- **Format specifiers** are the standard C ones — `%@` for objects/strings,
  `%lld` for `Int`. SwiftUI auto-maps Swift interpolation: `\(someString)` →
  `%@`, `\(someInt)` → `%lld`, etc.
- **Comments** in the catalog become the translator's hint. Use them when the
  source string is ambiguous out of context.
