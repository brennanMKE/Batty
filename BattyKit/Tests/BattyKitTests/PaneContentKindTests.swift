// PaneContentKindTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Covers `PaneContentKind` (#0302's design, `docs/pane-kinds.md`) and the
/// `PaneRuntime`/`Pane` `kind` field #0315 wires in: the identifier set
/// agents and scripts hard-code, `PaneRuntime`'s default-to-terminal
/// behavior, and `Pane`'s backward-compatible Codable decode (an absent
/// `kind` key — any snapshot written before this field existed — must
/// decode as `.terminal`, the only kind that existed then).
@MainActor
struct PaneContentKindTests {

    // MARK: - Identifier set (public contract — reconciled across the four
    // docs/design/*.md documents per #0315's instructions: git-status.md,
    // process-status-view.md, and system-metrics-view.md name their kinds
    // "git-status"/"process-status"/"system-metrics" respectively;
    // lmstudio-dashboard-view.md names its kind "lm-studio-dashboard" —
    // longer than the "lm-studio" issues/0315.md's own text used, and this
    // is the string that wins, per that design doc's own §5 "one string,
    // three call sites" rule and the fact it postdates the issue text.)

    @Test func identifierSetMatchesTheReconciledDesignDocs() {
        let identifiers = Set(PaneContentKind.allCases.map(\.rawValue))
        #expect(identifiers == [
            "terminal",
            "git-status",
            "process-status",
            "lm-studio-dashboard",
            "system-metrics",
        ])
    }

    @Test func everyNonTerminalIdentifierIsKebabCase() {
        for kind in PaneContentKind.allCases where kind != .terminal {
            #expect(kind.rawValue == kind.rawValue.lowercased())
            #expect(!kind.rawValue.contains("_"))
            #expect(!kind.rawValue.contains(" "))
        }
    }

    @Test func rawValueRoundTripsToTheSameCase() {
        for kind in PaneContentKind.allCases {
            #expect(PaneContentKind(rawValue: kind.rawValue) == kind)
        }
    }

    @Test func unknownRawValueFailsToConstruct() {
        #expect(PaneContentKind(rawValue: "bogus-kind") == nil)
    }

    @Test func everyCaseHasANonEmptyDisplayName() {
        for kind in PaneContentKind.allCases {
            #expect(!kind.displayName.isEmpty)
        }
    }

    // MARK: - `PaneRuntime.kind`

    @Test func paneRuntimeDefaultsToTerminalKind() {
        #expect(PaneRuntime().kind == .terminal)
    }

    @Test func paneRuntimeAcceptsAnExplicitNonTerminalKind() {
        #expect(PaneRuntime(kind: .gitStatus).kind == .gitStatus)
    }

    @Test func paneRuntimeSnapshotCarriesItsKind() {
        let pane = PaneRuntime(kind: .systemMetrics)
        #expect(pane.snapshot().kind == .systemMetrics)
    }

    // MARK: - `SessionRuntime.focusedTerminalPane` (#0315 review round 2, finding 2)

    /// The single accessor every Tab-scoped command dispatch path (menu
    /// bar, `BattyShortcuts`' NSEvent monitor, Command Palette) must route
    /// through — see `SessionRuntime.focusedTerminalPane`'s doc comment.

    @Test func focusedTerminalPaneReturnsTheFocusedPaneWhenItIsTerminalKind() {
        let session = SessionRuntime()
        #expect(session.focusedPane.kind == .terminal, "test setup: a fresh session's default pane is terminal-kind")

        #expect(session.focusedTerminalPane?.id == session.focusedPane.id)
    }

    @Test func focusedTerminalPaneIsNilWhenTheFocusedPaneIsNonTerminal() {
        let session = SessionRuntime()
        let terminalPane = session.focusedPane
        let nonTerminalPane = session.tree.splitPane(id: terminalPane.id, direction: .horizontal, kind: .lmStudioDashboard)!
        #expect(session.tree.focusedPaneID == nonTerminalPane.id, "test setup: splitting the focused pane must move focus to it")

        #expect(session.focusedTerminalPane == nil)
    }

    // MARK: - `Pane` Codable — absent-key-decodes-to-terminal
    // (`docs/pane-kinds.md` §4)

    @Test func paneDefaultInitProducesTerminalKind() {
        #expect(Pane().kind == .terminal)
    }

    @Test func paneEncodesKindExplicitly() throws {
        let pane = Pane(id: UUID(), isHidden: false, kind: .processStatus)
        let data = try JSONEncoder().encode(pane)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["kind"] as? String == "process-status")
    }

    @Test func paneRoundTripsAnExplicitNonTerminalKind() throws {
        let pane = Pane(id: UUID(), isHidden: true, kind: .lmStudioDashboard)
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(Pane.self, from: data)
        #expect(decoded == pane)
        #expect(decoded.kind == .lmStudioDashboard)
    }

    /// The load-bearing case: a JSON object with no `kind` key at all —
    /// exactly what every snapshot written before this field existed looks
    /// like — must decode as `.terminal`, not fail and not default to some
    /// other case.
    @Test func paneDecodesAnAbsentKindKeyAsTerminal() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isHidden":false}
        """
        let decoded = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.isHidden == false)
        #expect(decoded.kind == .terminal)
    }

    @Test func paneDecodesAnExplicitNullKindKeyAsTerminal() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isHidden":false,"kind":null}
        """
        let decoded = try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        #expect(decoded.kind == .terminal)
    }

    /// `docs/pane-kinds.md` §4: an unknown kind raw value must fail the
    /// decode loudly (the default `Codable` behavior for a `String`-backed
    /// `RawRepresentable` enum), not silently misrepresent an unrecognized
    /// pane as `.terminal`.
    @Test func paneDecodeThrowsForAnUnrecognizedKindRawValue() {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","isHidden":false,"kind":"not-a-real-kind"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Pane.self, from: Data(json.utf8))
        }
    }
}
