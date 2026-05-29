# Surfacing Local Swift Package Unit Tests in an Xcode Project

## Problem

An Xcode project consumes a **local** Swift package (added via path / "Add Local…").
The package contains a test target (e.g. `MyPackageTests`), but the tests do **not**
appear in the Test navigator (⌘6), have no gutter diamonds, and can't be run from
the IDE the way the app's own tests can.

This is expected default behavior: Xcode does **not** auto-add a local package's test
target to any scheme. The package being linked is not enough — the test target must be
explicitly registered in the scheme's Test action (or a test plan).

---

## Required conditions (all must be true)

1. The package is added to the project/workspace as a **local package dependency**
   (File → Add Package Dependencies → Add Local…), not merely opened standalone.
2. The package's **library product is linked** to at least one project target
   (General → Frameworks, Libraries, and Embedded Content). Without a build dependency
   path, Xcode won't compile/index the package's test bundle.
3. The package's **test target is explicitly enabled** in the scheme's Test action
   or in a test plan.
4. Standard build configuration names (`Debug`/`Release`) are used, OR a test plan is
   used. Custom-named configurations cause the package test bundle to build to a path
   Xcode doesn't look in at run time.

---

## Fix — manual steps (source of truth)

These are the GUI steps Claude Code must reproduce by editing the right files.

1. **Add the local package** (if not already):
   File → Add Package Dependencies… → Add Local… → select the package folder.

2. **Link the product** to a target:
   Project → target → General → Frameworks, Libraries, and Embedded Content → **+** →
   add the package library product.

3. **Enable the test target in the scheme:**
   Product → Scheme → Edit Scheme… → **Test** (left) → under **Tests**, click **+** →
   add the package's test target (e.g. `MyPackageTests`).

4. **Build & verify:**
   ⌘B, then open the Test navigator (⌘6). Tests should now appear with diamonds.

---

## What Claude Code actually needs to edit

The GUI actions above persist into specific files on disk. Claude Code should make these
edits directly rather than relying on `xcodebuild` to do it.

### A. The scheme `.xcscheme` file

Location:
```
<Project>.xcodeproj/xcshareddata/xcschemes/<Scheme>.xcscheme
```
or, if not shared:
```
<Project>.xcodeproj/xcuserdata/<user>.xcuserdatad/xcschemes/<Scheme>.xcscheme
```

Inside `<TestAction>` there is a `<Testables>` element. Add a `<TestableReference>`
pointing at the package test target. For a local Swift package, the
`BuildableReference` uses the **package's** container path and the test target's
blueprint name. Example:

```xml
<TestAction
   buildConfiguration = "Debug"
   ... >
   <Testables>
      <!-- existing app test target(s) ... -->
      <TestableReference
         skipped = "NO">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "MyPackageTests"
            BuildableName = "MyPackageTests"
            BlueprintName = "MyPackageTests"
            ReferencedContainer = "container:MyPackage">
         </BuildableReference>
      </TestableReference>
   </Testables>
</TestAction>
```

Notes on `ReferencedContainer`:
- For a local package added by path, the form is `container:<PackageDirName>`
  (the directory name of the package as referenced in the project), NOT a
  `.xcodeproj` path.
- `BlueprintName` / `BuildableName` / `BlueprintIdentifier` are all the test target
  name as declared in `Package.swift` (the `.testTarget(name:)` value).

### B. Confirm the package reference exists in `project.pbxproj`

Location:
```
<Project>.xcodeproj/project.pbxproj
```
Verify there is an `XCLocalSwiftPackageReference` (Xcode 15+) or a
`XCSwiftPackageProductDependency` for the package, and that the library product is
listed in the consuming target's `Frameworks` build phase. If the product isn't
linked, add it — the scheme edit alone won't surface tests without a build path.

### C. (Preferred for reliability) Use a test plan

If the scheme route is flaky, convert to a `.xctestplan`:

1. Product → Scheme → Edit Scheme → Test → **Convert to use Test Plans…**
2. Edit the generated `<Name>.xctestplan` (a JSON file) and add the package test
   target to `testTargets`:

```json
{
  "configurations": [ { "id": "...", "name": "Configuration 1", "options": {} } ],
  "defaultOptions": {},
  "testTargets": [
    {
      "target": {
        "containerPath": "container:MyPackage",
        "identifier": "MyPackageTests",
        "name": "MyPackageTests"
      }
    }
  ],
  "version": 1
}
```

The `.xctestplan` is referenced from `<TestAction>` in the `.xcscheme` via
`<TestPlans><TestPlanReference reference = "container:MyTestPlan.xctestplan" /></TestPlans>`.

---

## Verification (command line)

After editing, verify Xcode can see the tests without opening the GUI:

```bash
# List what the scheme exposes
xcodebuild -project <Project>.xcodeproj -scheme <Scheme> -showTestPlans

# Enumerate tests without running them
xcodebuild test-without-building \
  -project <Project>.xcodeproj \
  -scheme <Scheme> \
  -destination 'platform=macOS' \
  -only-testing:MyPackageTests \
  2>&1 | grep -i "Test Case"

# Or build-for-testing then inspect
xcodebuild build-for-testing \
  -project <Project>.xcodeproj \
  -scheme <Scheme> \
  -destination 'platform=macOS'
```

If `-only-testing:MyPackageTests` runs the package tests, the scheme/plan wiring is
correct.

---

## Common failure modes (why repeated attempts fail)

- **Scheme edited but product not linked.** Adding `<TestableReference>` without the
  library being in a target's Frameworks phase → tests don't compile/index → empty
  navigator. Fix step B.
- **Wrong `ReferencedContainer`.** Using a `.xcodeproj` container path instead of
  `container:<PackageDir>` → Xcode silently ignores the reference.
- **Editing a user scheme that isn't the active one** (`xcuserdata` vs
  `xcshareddata`). Edit the scheme actually selected, or mark the scheme **Shared**
  and edit the file under `xcshareddata`.
- **Custom build configuration names.** Package test bundle builds to a path Xcode
  doesn't search → "Failed to create a bundle instance representing
  '…/SomePackageTests.xctest'. Check that the bundle exists on disk." Use Debug/Release
  or switch to a test plan.
- **Stale state.** After edits: File → Packages → Reset Package Caches; delete
  DerivedData; ⇧⌘K clean; rebuild. From CLI:
  `rm -rf ~/Library/Developer/Xcode/DerivedData/<Project>-*`.

---

## Minimal checklist for Claude Code

1. [ ] Local package present in `project.pbxproj` (`XCLocalSwiftPackageReference`).
2. [ ] Package library product linked in a target's Frameworks build phase.
3. [ ] `<TestableReference>` for the package test target added to the scheme's
       `<TestAction>` with `ReferencedContainer = "container:<PackageDir>"`.
4. [ ] Scheme is the active/shared one being edited.
5. [ ] Build configs are Debug/Release (or a test plan is used).
6. [ ] `xcodebuild test-without-building -only-testing:<TestTarget>` succeeds.
7. [ ] Reset package caches + clean DerivedData, then verify diamonds in ⌘6.
