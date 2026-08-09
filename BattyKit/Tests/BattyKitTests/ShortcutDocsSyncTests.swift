// ShortcutDocsSyncTests.swift

import Foundation
import SwiftUI
import Testing
@testable import BattyKit

/// Pins the shortcut chords documented in the shipped in-app Help catalog
/// (`BattyKit/Sources/BattyKit/Help/05-shortcuts.md`) and the developer doc
/// (`docs/shortcuts.md`) to `ShortcutAction.defaultBinding` — the single
/// source of truth for default chords. Written for #0329, filed after #0326
/// and #0328 each had to hand-correct dozens of drifted chords with nothing
/// stopping the next drift.
///
/// Both files are parsed as markdown pipe tables (see `parseTables(in:headerColumns:)`
/// below), which means **the table format is load-bearing**: renaming a
/// heading, reordering columns, or switching to a bullet list will make the
/// parser find zero matching rows. A zero-row parse is treated as a failure,
/// not a vacuous pass — see `helpCatalogTableIsNonEmpty` and
/// `docsCatalogTableIsNonEmpty` — so a reformat can't silently disable the
/// guard.
///
/// `ShortcutBinding.displayString` renders glyph form (`⌘⇧B`) for the
/// Settings UI; both docs write prose (`Cmd-Shift-B`). `proseDefault(for:)`
/// is this test's own prose renderer — independent of `displayString` — so
/// the comparison isn't just checking a renderer against itself.
///
/// `docs/shortcuts.md` doesn't ship inside the app, but #0326 established it
/// drifts identically to the in-app catalog — and drifted in *both* of its
/// shortcut tables simultaneously (commit `4bd44fc` had to fix the same
/// wrong chord in Section 1 and Section 2 separately). So both are covered:
///
/// - **Section 2** ("Catalog of customizable actions") gets correctness
///   *and* completeness — it's the one table in the file explicitly claimed
///   to be complete, and it's keyed by `rawValue`, which sidesteps the
///   display-name-matching this file otherwise relies on.
/// - **Section 1** ("frequently used defaults") gets correctness only. Its
///   own prose says it's "a curated subset, not the complete catalog," so
///   it's exempt from the completeness assertion and the non-empty guard —
///   but a curated subset still has to state the right chords, and #0326
///   proved this exact table drifts independently of Section 2.
struct ShortcutDocsSyncTests {

    // MARK: - File locations

    private static func repoRootURL() -> URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/ShortcutDocsSyncTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .deletingLastPathComponent() // -> repo root
    }

    private static func helpCatalogURL() -> URL {
        repoRootURL().appending(
            path: "BattyKit/Sources/BattyKit/Help/05-shortcuts.md",
            directoryHint: .notDirectory
        )
    }

    private static func docsCatalogURL() -> URL {
        repoRootURL().appending(path: "docs/shortcuts.md", directoryHint: .notDirectory)
    }

    // MARK: - Prose renderer

    /// Renders `action.defaultBinding` in the prose form both docs use
    /// (`Cmd-Shift-D`, `Cmd-Ctrl-←`), independent of
    /// `ShortcutBinding.displayString`'s glyph form (`⌘⇧D`). Modifier order
    /// is fixed (Cmd, Shift, Option, Ctrl) to match every example present in
    /// both files as of this writing — verified by hand against
    /// `docs/shortcuts.md`'s Section 2 table before being trusted here.
    private static func proseDefault(for action: ShortcutAction) -> String {
        let binding = action.defaultBinding
        let mods = EventModifiers(rawValue: binding.modifiers)
        var parts: [String] = []
        if mods.contains(.command) { parts.append("Cmd") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.option) { parts.append("Option") }
        if mods.contains(.control) { parts.append("Ctrl") }

        let keyPart: String
        if let special = binding.specialKey {
            keyPart = special.glyph
        } else {
            keyPart = binding.key.uppercased()
        }
        parts.append(keyPart)
        return parts.joined(separator: "-")
    }

    // MARK: - Minimal markdown pipe-table parser

    /// Strips backtick code-span markers and surrounding whitespace, e.g.
    /// `` "`Cmd-N`" `` -> `"Cmd-N"`.
    private static func stripCodeSpan(_ cell: String) -> String {
        cell.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "")
    }

    private static func parseRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        guard let cells = parseRow(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
        }
    }

    /// Scans `markdown` for every pipe table whose header row's cells —
    /// after stripping code-span backticks — equal `headerColumns` exactly,
    /// and returns each table's data rows (raw cells, code spans intact).
    /// Multiple matching tables in one document are all included, so this
    /// works for `05-shortcuts.md`'s four "Action | Default" subsections.
    private static func parseTables(in markdown: String, headerColumns: [String]) -> [[String]] {
        let lines = markdown.components(separatedBy: "\n")
        var rows: [[String]] = []
        var i = 0
        while i < lines.count {
            if let header = parseRow(lines[i]),
               header.map(stripCodeSpan) == headerColumns,
               i + 1 < lines.count,
               isSeparatorRow(lines[i + 1]) {
                var j = i + 2
                while j < lines.count, let row = parseRow(lines[j]) {
                    rows.append(row)
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return rows
    }

    // MARK: - 05-shortcuts.md (shipped in-app Help catalog)

    /// Action names that deliberately live outside `ShortcutAction` (system
    /// standards or positional bindings — see `ShortcutAction.swift`'s doc
    /// comment and `05-shortcuts.md`'s "Fixed shortcuts" section) and so are
    /// exempt from both the correctness and completeness assertions below.
    private static let nonCatalogHelpActionNames: Set<String> = [
        "Select Session 1–9",
        "Select Tab 1–9",
        "Settings",
        "Help",
        "Copy",
        "Paste",
        "Quit",
    ]

    /// `ShortcutAction.displayName` is the join key for every table that
    /// names actions by prose rather than `rawValue` (both Help sections and
    /// `docs/shortcuts.md` Section 1). `ShortcutAction`'s cases are
    /// hand-authored with distinct display names today, so this is safe;
    /// nothing currently enforces that at the type level.
    private static let byDisplayName: [String: ShortcutAction] = Dictionary(
        uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.displayName, $0) }
    )

    private static func helpCatalogRows() throws -> [[String]] {
        let text = try String(contentsOf: helpCatalogURL(), encoding: .utf8)
        return parseTables(in: text, headerColumns: ["Action", "Default"])
    }

    @Test func helpCatalogTableIsNonEmpty() throws {
        // Guards against the parser silently finding nothing (renamed
        // heading, restructured table) and every other test in this file
        // passing vacuously as a result.
        let rows = try Self.helpCatalogRows()
        #expect(rows.count >= ShortcutAction.allCases.count)
    }

    @Test func helpCatalogChordsMatchDefaultBindings() throws {
        let rows = try Self.helpCatalogRows()
        #expect(!rows.isEmpty)

        for row in rows {
            guard row.count == 2 else {
                Issue.record("05-shortcuts.md: malformed row \(row)")
                continue
            }
            let name = row[0]
            let chord = Self.stripCodeSpan(row[1])

            if let action = Self.byDisplayName[name] {
                let expected = Self.proseDefault(for: action)
                #expect(
                    chord == expected,
                    "05-shortcuts.md: \(action.rawValue) documents '\(chord)' but defaultBinding is '\(expected)'"
                )
            } else {
                #expect(
                    Self.nonCatalogHelpActionNames.contains(name),
                    "05-shortcuts.md: '\(name)' matches no ShortcutAction.displayName and isn't in the known non-catalog allow-list"
                )
            }
        }
    }

    @Test func helpCatalogListsEveryShortcutAction() throws {
        let rows = try Self.helpCatalogRows()
        #expect(!rows.isEmpty)
        let namedInCatalog = Set(rows.map { $0.first ?? "" })
        let missing = ShortcutAction.allCases.filter { !namedInCatalog.contains($0.displayName) }
        #expect(missing.isEmpty, "05-shortcuts.md is missing: \(missing.map(\.rawValue).sorted())")
    }

    // MARK: - docs/shortcuts.md (Section 2 catalog table)

    private static func docsCatalogRows() throws -> [[String]] {
        let text = try String(contentsOf: docsCatalogURL(), encoding: .utf8)
        return parseTables(in: text, headerColumns: ["rawValue", "Display name", "Default", "Action"])
    }

    @Test func docsCatalogTableIsNonEmpty() throws {
        let rows = try Self.docsCatalogRows()
        #expect(rows.count >= ShortcutAction.allCases.count)
    }

    @Test func docsCatalogChordsMatchDefaultBindings() throws {
        let rows = try Self.docsCatalogRows()
        #expect(!rows.isEmpty)

        for row in rows {
            guard row.count == 4 else {
                Issue.record("docs/shortcuts.md: malformed catalog row \(row)")
                continue
            }
            let rawValue = Self.stripCodeSpan(row[0])
            let chord = Self.stripCodeSpan(row[2])
            guard let action = ShortcutAction(rawValue: rawValue) else {
                Issue.record("docs/shortcuts.md: unknown rawValue '\(rawValue)' in catalog table")
                continue
            }
            let expected = Self.proseDefault(for: action)
            #expect(
                chord == expected,
                "docs/shortcuts.md: \(rawValue) documents '\(chord)' but defaultBinding is '\(expected)'"
            )
        }
    }

    @Test func docsCatalogListsEveryShortcutAction() throws {
        let rows = try Self.docsCatalogRows()
        #expect(!rows.isEmpty)
        let rawValuesInDocs = Set(rows.compactMap { $0.count == 4 ? Self.stripCodeSpan($0[0]) : nil })
        let missing = ShortcutAction.allCases.filter { !rawValuesInDocs.contains($0.rawValue) }
        #expect(missing.isEmpty, "docs/shortcuts.md catalog table is missing: \(missing.map(\.rawValue).sorted())")
    }

    // MARK: - docs/shortcuts.md (Section 1 curated-subset table)

    /// Section 1's own prose calls this "a curated subset, not the complete
    /// catalog" — so no completeness assertion or non-empty guard here, only
    /// correctness. #0326 fixed a wrong chord in this exact table
    /// independently of Section 2, so a subset is not a reason to skip
    /// checking the rows it does have.
    private static func docsSection1Rows() throws -> [[String]] {
        let text = try String(contentsOf: docsCatalogURL(), encoding: .utf8)
        return parseTables(in: text, headerColumns: ["Action", "Default", "Notes"])
    }

    @Test func docsSection1ChordsMatchDefaultBindings() throws {
        let rows = try Self.docsSection1Rows()
        #expect(!rows.isEmpty)

        for row in rows {
            guard row.count == 3 else {
                Issue.record("docs/shortcuts.md: malformed Section 1 row \(row)")
                continue
            }
            let name = row[0]
            let chord = Self.stripCodeSpan(row[1])

            if let action = Self.byDisplayName[name] {
                let expected = Self.proseDefault(for: action)
                #expect(
                    chord == expected,
                    "docs/shortcuts.md Section 1: \(action.rawValue) documents '\(chord)' but defaultBinding is '\(expected)'"
                )
            } else {
                #expect(
                    Self.nonCatalogHelpActionNames.contains(name),
                    "docs/shortcuts.md Section 1: '\(name)' matches no ShortcutAction.displayName and isn't in the known non-catalog allow-list"
                )
            }
        }
    }
}
