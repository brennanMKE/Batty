# Project Name Extraction Reference

A reference for deriving a project's name from build artifacts found in the root folder of a software package. Designed as a lookup for Claude Code or any tool that needs to identify "what is this project called?" by inspecting filesystem signals.

## How to use this document

Each ecosystem entry lists:

- **Detect** — files whose presence in the root signals this ecosystem.
- **Extract** — exact location of the name within the file (path, key, regex, etc.).
- **Fallback** — what to do when the canonical field is absent.

When multiple ecosystems match (e.g. a Python project with a `Dockerfile`), use the **Resolution priority** section at the bottom of the document.

---

## Quick reference table

| Ecosystem | Primary file | Name location |
|---|---|---|
| Node.js / npm / pnpm / Yarn / Bun | `package.json` | `.name` |
| Deno | `deno.json` / `deno.jsonc` / `jsr.json` | `.name` |
| Python | `pyproject.toml` | `[project].name` or `[tool.poetry].name` |
| Python (legacy) | `setup.cfg`, `setup.py` | `[metadata].name` / `setup(name=…)` |
| Rust | `Cargo.toml` | `[package].name` |
| Go | `go.mod` | last path segment of `module` directive |
| Java/Kotlin (Gradle) | `settings.gradle[.kts]` | `rootProject.name` |
| Java (Maven) | `pom.xml` | `/project/artifactId` |
| Swift (SPM) | `Package.swift` | `Package(name: "…")` |
| Swift (Xcode) | `*.xcodeproj` / `*.xcworkspace` | directory basename minus extension |
| Ruby | `*.gemspec` | `spec.name = …` |
| Ruby (Rails) | `config/application.rb` | `module Name` |
| PHP | `composer.json` | `.name` (in `vendor/package` form) |
| .NET / C# / F# / VB | `*.csproj` / `*.fsproj` / `*.vbproj` / `*.sln` | filename without extension |
| C/C++ (CMake) | `CMakeLists.txt` | first arg to `project(...)` |
| C/C++ (Meson) | `meson.build` | first arg to `project('…', …)` |
| Dart / Flutter | `pubspec.yaml` | `name:` |
| Elixir | `mix.exs` | `app:` in `project/0` |
| Erlang | `rebar.config` / `*.app.src` | `{application, name, …}` |
| Haskell (Cabal) | `*.cabal` | `name:` field |
| Haskell (Stack) | `package.yaml` | `name:` |
| Scala (sbt) | `build.sbt` | `name :=` |
| Clojure (Leiningen) | `project.clj` | second form of `defproject` |
| Clojure (deps) | `deps.edn` | no canonical name → use directory |
| R | `DESCRIPTION` | `Package:` |
| Julia | `Project.toml` | `name = "…"` |
| Lua (LuaRocks) | `*.rockspec` | `package = "…"` or filename prefix |
| Nim | `*.nimble` | filename without extension |
| Crystal | `shard.yml` | `name:` |
| OCaml (Dune) | `dune-project` | `(name …)` |
| OCaml (opam) | `*.opam` | filename without extension |
| Perl | `Makefile.PL`, `Build.PL`, `META.json`, `cpanfile` | `name`, `WriteMakefile(NAME=…)` |
| Zig | `build.zig.zon` / `build.zig` | `.name = .…` / `addExecutable(.name=…)` |
| Unity | `ProjectSettings/ProjectSettings.asset` | `productName:` |
| Unreal | `*.uproject` | filename without extension |
| Godot | `project.godot` | `config/name=` |
| Android | `settings.gradle[.kts]` | `rootProject.name` (or `applicationId` in `app/build.gradle`) |
| Docker (Compose only) | `compose.yaml` / `docker-compose.yml` | top-level `name:` (newer Compose spec) or directory basename |

---

## JavaScript and TypeScript ecosystems

### Node.js, npm, pnpm, Yarn, Bun

- **Detect:** `package.json` in root. (Lockfiles `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb` indicate which package manager but do not affect name resolution.)
- **Extract:** `name` field at the top level. May be scoped (`@scope/pkg-name`).
- **Fallback:** if `name` is missing or empty, fall back to the directory name. If `private: true` and no `name`, the directory name is the most accurate signal.
- **Monorepos:** if `workspaces` is present, the root `package.json` name is the workspace root name; individual packages live in subdirectories with their own `package.json`.

```json
{ "name": "@acme/widget" }
```

### Deno

- **Detect:** `deno.json` or `deno.jsonc` in root (also `jsr.json` for JSR-published packages).
- **Extract:** `name` field at the top level. JSR packages use scoped names like `@scope/pkg`.
- **Fallback:** Deno projects may not have a `name` field if they aren't intended for JSR publishing. In that case use the directory name. If `package.json` is also present, prefer `deno.json` over it for Deno-specific tooling.

```json
{ "name": "@luca/greet", "version": "1.0.0", "exports": "./mod.ts" }
```

---

## Python

### Modern (PEP 621)

- **Detect:** `pyproject.toml` in root.
- **Extract (in priority order):**
  1. `[project] name` — PEP 621 standard, used by Hatch, Flit, setuptools (modern), PDM, uv.
  2. `[tool.poetry] name` — Poetry-managed projects (Poetry < 2.0; Poetry 2.0+ uses `[project]`).
- **Fallback:** if `pyproject.toml` exists but neither table is present, check `[tool.setuptools]` `name`, then fall back to legacy files.

```toml
[project]
name = "my-package"
```

### Legacy

- **Detect:** `setup.py` or `setup.cfg` in root (often alongside or instead of `pyproject.toml`).
- **Extract:**
  - `setup.cfg`: `[metadata] name = …`
  - `setup.py`: `name="…"` argument inside the `setup(...)` call. Treat as text — do not exec it. A regex like `setup\([^)]*?name\s*=\s*["']([^"']+)["']` is sufficient for the common case, but `setup.py` can construct the name dynamically; if so, defer to `pyproject.toml` or the directory name.

### Notes

- The PyPI distribution name (with hyphens) and the importable Python package name (with underscores) often differ. The name in `pyproject.toml` is the distribution name and is what most users mean by "project name."
- Conda projects: `meta.yaml` under `recipe/` or `conda/`, key `package.name`.

---

## Rust

- **Detect:** `Cargo.toml` in root. Often accompanied by `Cargo.lock`.
- **Extract:** `[package] name` field.
- **Workspaces:** if `[workspace]` is present and `[package]` is absent, this is a virtual manifest — the workspace itself has no name; use the directory basename, and member crates live in subdirectories.

```toml
[package]
name = "my-crate"
version = "0.1.0"
```

---

## Go

- **Detect:** `go.mod` in root.
- **Extract:** the `module` directive's value, then take the **last path segment** as the project name.

```
module github.com/acme/widget
```

Project name → `widget`. The full module path is also valuable as a fully-qualified identifier.

- **Fallback:** if no `go.mod`, the project predates modules — use the directory name.

---

## JVM ecosystems

### Gradle (Java, Kotlin, Android, Scala-via-Gradle)

- **Detect:** `settings.gradle` or `settings.gradle.kts` in root (also `build.gradle[.kts]`).
- **Extract:** `rootProject.name = "…"` in the settings file. Quote style varies (single in Groovy, double in Kotlin DSL).
- **Fallback:** if `rootProject.name` is not set, Gradle itself defaults to the directory name — so the directory name is the correct fallback.

```kotlin
rootProject.name = "my-project"
include("app", "core")
```

### Maven

- **Detect:** `pom.xml` in root.
- **Extract:** `/project/artifactId` (XPath). For a fully-qualified identifier, combine with `/project/groupId` as `groupId:artifactId`.
- **Note:** `/project/name` is a human-readable display name and may differ from `artifactId`. Prefer `artifactId` as the canonical project name; use `name` only as a display label.

```xml
<project>
  <groupId>com.acme</groupId>
  <artifactId>widget</artifactId>
</project>
```

### Android specifically

- The Gradle `rootProject.name` is the project name.
- `applicationId` in `app/build.gradle[.kts]` (under `android.defaultConfig`) is the app's unique identifier on devices and the Play Store; useful as a secondary signal but is not the project name.

---

## Apple platforms (Swift, Objective-C, iOS, macOS)

### Swift Package Manager

- **Detect:** `Package.swift` in root.
- **Extract:** `name:` argument to the `Package(...)` initializer at the top of the manifest. Parse as text; don't execute it.

```swift
let package = Package(
    name: "MyLibrary",
    products: [...],
)
```

### Xcode projects and workspaces

- **Detect:** a `*.xcodeproj` directory or `*.xcworkspace` directory in root.
- **Extract:** the directory basename, stripped of the extension. For `MyApp.xcodeproj`, the project name is `MyApp`.
- **More precise:** `MyApp.xcodeproj/project.pbxproj` is a property-list-like text file; the canonical name is in the `PBXProject` section under `name`, and target names are listed under `PBXNativeTarget` blocks. Filename is reliable in 99% of cases — only parse `project.pbxproj` if the user needs target-level granularity.
- **CocoaPods:** `Podfile` or `*.podspec`. `*.podspec` files use Ruby DSL: `s.name = "…"`.

---

## Ruby

### Gems

- **Detect:** `*.gemspec` in root.
- **Extract:** `spec.name = "…"` (or `s.name = "…"`) inside the `Gem::Specification.new` block. Parse as text.
- **Filename convention:** the gemspec is conventionally named `<gem-name>.gemspec`, so the filename minus extension is a reliable fallback.

### Applications (Rails, Sinatra, etc.)

- **Detect:** `Gemfile` plus `config/application.rb` (Rails) or just `Gemfile` (other).
- **Extract (Rails):** the module name in `config/application.rb`: `module MyApp`. This becomes the Rails app constant.
- **Fallback:** `Gemfile` itself has no name field — use the directory name.

---

## PHP

- **Detect:** `composer.json` in root.
- **Extract:** `name` field in `vendor/package` form. The "project name" is typically the `package` portion (after the slash), but the full `vendor/package` is the canonical identifier.

```json
{ "name": "acme/widget" }
```

---

## .NET (C#, F#, VB)

- **Detect:** any of `*.sln`, `*.csproj`, `*.fsproj`, `*.vbproj` in root or one level deep.
- **Extract:** the filename without extension is the project name.
  - For solutions: `MyApp.sln` → solution name `MyApp`.
  - For individual projects: `MyApp.Web.csproj` → project name `MyApp.Web`.
- **More precise:** inside `*.csproj`, the `<AssemblyName>` and `<RootNamespace>` properties may differ from the filename. If `<AssemblyName>` is set explicitly, that's the assembly's output name; the filename is still the conventional project identifier.
- **Priority when both exist:** prefer the `.sln` filename when present (it's the umbrella project), otherwise the `.csproj`/`.fsproj`/`.vbproj` filename.

---

## C and C++

### CMake

- **Detect:** `CMakeLists.txt` in root.
- **Extract:** the first argument to the `project(...)` command at the top of the file.

```cmake
project(MyApp VERSION 1.0 LANGUAGES CXX)
```

Regex: `^\s*project\s*\(\s*([A-Za-z0-9_\-]+)`. Watch for `project()` calls in subdirectories — only the root file's call defines the top-level project name.

### Meson

- **Detect:** `meson.build` in root.
- **Extract:** first string argument to `project('...', ...)`.

```meson
project('my-app', 'cpp', version: '1.0.0')
```

### Plain Make

- **Detect:** `Makefile` or `GNUmakefile` in root.
- **Extract:** no standard name location. Some Makefiles set a `NAME =`, `PROJECT =`, or `TARGET =` variable near the top — heuristic only.
- **Fallback:** directory name.

### Bazel

- **Detect:** `MODULE.bazel` or `WORKSPACE`/`WORKSPACE.bazel` in root.
- **Extract:**
  - `MODULE.bazel`: `module(name = "...")`.
  - `WORKSPACE` (legacy): `workspace(name = "...")`.
- **Fallback:** directory name.

---

## Dart and Flutter

- **Detect:** `pubspec.yaml` in root.
- **Extract:** top-level `name:` field. Must be a valid Dart identifier (lowercase, underscores).

```yaml
name: my_app
description: A new Flutter project.
```

---

## Functional / niche languages

### Elixir

- **Detect:** `mix.exs` in root.
- **Extract:** the `app:` key inside the `project` function's return value. It's an atom like `:my_app`.

```elixir
def project do
  [app: :my_app, version: "0.1.0"]
end
```

### Erlang

- **Detect:** `rebar.config` plus `src/*.app.src`.
- **Extract:** in `*.app.src`, the second element of the application tuple: `{application, my_app, [...]}`. Filename `my_app.app.src` also encodes the name.

### Haskell

- **Cabal:** `*.cabal` file in root. Extract the `name:` field. The filename (e.g. `my-package.cabal`) also encodes the name.
- **Stack:** `package.yaml` plus `stack.yaml`. Extract `name:` from `package.yaml`.

### Scala (sbt)

- **Detect:** `build.sbt` in root, plus a `project/` directory.
- **Extract:** `name := "..."` line in `build.sbt`. Sbt is Scala code, so handle string interpolation cautiously — for the simple case, a regex is fine.
- **Fallback:** directory name (sbt uses it by default).

### Clojure

- **Leiningen:** `project.clj` in root. Extract the second form of `defproject`: `(defproject my-project "0.1.0" ...)`.
- **deps.edn / Clojure CLI:** `deps.edn` has no canonical name field. Use the directory name, or `:paths`/`:aliases` for hints.

### OCaml

- **Dune:** `dune-project` in root. Extract `(name foo)` stanza.
- **opam:** `*.opam` in root. The filename minus `.opam` is the package name.

### Perl

- **Detect (in priority order):** `META.json` / `META.yml` (richest), `Makefile.PL` (ExtUtils::MakeMaker), `Build.PL` (Module::Build), `cpanfile`, `dist.ini` (Dist::Zilla).
- **Extract:**
  - `META.json`: `name` field.
  - `Makefile.PL`: `NAME => '...'` arg to `WriteMakefile`.
  - `dist.ini`: `name = ...`.

### R

- **Detect:** `DESCRIPTION` file in root (Debian-control-style).
- **Extract:** `Package:` field on its own line.

```
Package: mypackage
Type: Package
Version: 0.1.0
```

### Julia

- **Detect:** `Project.toml` in root (and `Manifest.toml`).
- **Extract:** top-level `name = "..."`.

### Lua (LuaRocks)

- **Detect:** `*.rockspec` in root. Filename pattern is `<name>-<version>.rockspec`, so the filename prefix is the name.
- **Extract:** also has `package = "..."` inside the file.

### Crystal

- **Detect:** `shard.yml` in root.
- **Extract:** `name:` field.

### Nim

- **Detect:** `*.nimble` in root.
- **Extract:** filename without `.nimble` is the package name.

### Zig

- **Detect:** `build.zig.zon` (Zig 0.11+) or `build.zig` in root.
- **Extract:**
  - `build.zig.zon`: `.name = .my_project` (note: in modern Zig the name is a `.enum_literal`, not a string).
  - `build.zig`: arguments to `b.addExecutable(.{ .name = "..." })` or `b.addStaticLibrary(...)`. There can be multiple — pick the one matching the directory or the first one.

---

## Game engines

### Unity

- **Detect:** `Assets/`, `ProjectSettings/`, `Packages/` directories at root.
- **Extract:** in `ProjectSettings/ProjectSettings.asset` (a YAML-tagged file), the `productName:` field. Also `bundleIdentifier`.
- **Fallback:** directory name. Unity does not maintain a true "project name" anywhere — `productName` is what's displayed in builds.

### Unreal Engine

- **Detect:** `*.uproject` file in root.
- **Extract:** filename without `.uproject` is the project name (e.g. `MyGame.uproject` → `MyGame`). The file itself is JSON with metadata but no `name` field; the filename is authoritative.

### Godot

- **Detect:** `project.godot` in root (INI-style).
- **Extract:** `config/name="..."` inside the `[application]` section.

```ini
[application]
config/name="My Game"
```

---

## Containers and orchestration

### Docker / Compose

- **Dockerfile alone:** no project name — Docker images are tagged at build time. Fall back to the directory name.
- **Compose:** `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`. The Compose spec supports a top-level `name:` field for the project (overriding the implicit directory-based name). If absent, Compose uses the directory name lowercased with non-alphanumerics stripped.

### Kubernetes (Helm)

- **Detect:** `Chart.yaml` in root.
- **Extract:** `name:` field.

### Terraform

- **Detect:** `*.tf` files in root, possibly `main.tf`, `versions.tf`.
- **Extract:** no canonical project name. The directory name is conventionally used. If a `terraform { backend "..." { key = "..." } }` block names the state file, that's a hint.

---

## Resolution priority (when multiple match)

A project root often contains files from multiple ecosystems (e.g. a Rust app with a `Dockerfile`, a Python package with a `package.json` for JS tooling). When deriving a single canonical project name, walk this priority order and use the first matching ecosystem:

1. **Native build manifests over auxiliary tooling.** Prefer `Cargo.toml` over `Dockerfile`; prefer `pyproject.toml` over a docs site's `package.json`.
2. **Within-ecosystem priority — modern over legacy:**
   - Python: `pyproject.toml` → `setup.cfg` → `setup.py`.
   - JVM: Gradle `settings.gradle[.kts]` → `pom.xml` → `build.gradle` (without settings).
   - Swift: `Package.swift` → `.xcworkspace` → `.xcodeproj`.
   - Perl: `META.json` → `dist.ini` → `Makefile.PL` → `Build.PL`.
3. **Among build manifests of equal weight,** prefer the one whose lockfile / companion file is also present (signal that the project is actively built with that tool).
4. **If the manifest is present but the name field is empty or missing,** fall back to the directory basename — this matches what every modern build tool (Cargo, Gradle, Compose, sbt) does internally.
5. **Sanitize the directory-name fallback:** strip leading dots, decode URL/percent-encoding from clones, replace spaces and other shell-hostile characters with hyphens.

---

## Edge cases and gotchas

- **Monorepos.** A root `package.json` with `workspaces`, a Cargo virtual manifest, or a Gradle multi-project build represents an umbrella, not a single deliverable. The "project name" of the umbrella is real and useful — but tooling that wants to operate on a specific deliverable should descend into subdirectories.
- **Display name vs. identifier.** Many ecosystems distinguish:
  - **Identifier** — used by package managers, must be unique, conventionally kebab-case or snake_case (e.g. Maven `artifactId`, npm `name`, Cargo `name`).
  - **Display name** — human-friendly, may contain spaces (e.g. Maven `<name>`, Unity `productName`, Godot `config/name`).
  
  When in doubt, prefer the identifier — display names are presentation, not identity.
- **Scoped names.** npm (`@scope/pkg`), JSR (`@scope/pkg`), Composer (`vendor/pkg`), Maven (`groupId:artifactId`) all use compound identifiers. Decide whether to keep the scope or strip it. For most "what is this project called" purposes, the unscoped portion is what humans say; the full scoped form is what tooling needs.
- **Case sensitivity.** npm names are lowercase by spec, Cargo names are case-preserving but case-insensitive on crates.io, Maven `artifactId` is case-sensitive. Normalize cautiously — lowercasing can collide.
- **Dynamic names.** `setup.py` can compute its name at runtime; `build.gradle` can set `rootProject.name` from an environment variable; `build.sbt` can interpolate. If text parsing doesn't yield a literal string, the safest fallback is the directory name.
- **Empty `name` fields.** Some `package.json` files in monorepo subroots set `"name": ""` or omit it entirely with `"private": true`. Treat these as "no name" and fall back.
- **Vendored dependencies.** A `vendor/`, `third_party/`, or `node_modules/` directory can contain `package.json` files from other projects. Only inspect files in the root being analyzed.

---

## Implementation hints for Claude Code

When asked "what is this project called?":

1. List the root directory's contents.
2. Match against the priority table above to identify the ecosystem.
3. Parse the relevant manifest with a real parser when one is cheap and standard (`tomllib` for TOML, `json` for JSON, `yaml` for YAML, `xml.etree` for `pom.xml`). For Groovy/Kotlin/Ruby/Swift/Elixir DSL files, a targeted regex is acceptable for the common case — fall back to the directory name on parse failure.
4. If parsing yields a literal string, return it.
5. If parsing fails or the field is missing, return the directory basename as the fallback.
6. When relevant, also surface the **full identifier** (e.g. `groupId:artifactId`, `@scope/pkg`, `github.com/owner/repo`) since that's often what downstream tooling needs.
