// ProjectTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

@MainActor
struct ProjectTests {
    private func roundTrip(_ project: Project) throws -> Project {
        let data = try ProjectsFile.encoder.encode(project)
        return try ProjectsFile.decoder.decode(Project.self, from: data)
    }

    @Test func roundTripsEveryPaneKindTabsAndNestedTopology() throws {
        let terminal = ProjectPane.terminal(tabs: [
            ProjectTab(title: "server", workingDirectory: "src/app", startupCommand: "npm run dev"),
            ProjectTab(title: nil, workingDirectory: ".", startupCommand: nil),
        ])
        let nested = ProjectLayoutNode.split(direction: .horizontal, children: [
            .pane(terminal),
            .split(direction: .vertical, children: [
                .pane(ProjectPane(kind: .gitStatus, repositoryPath: "sub/repo")),
                .split(direction: .horizontal, children: [
                    .pane(ProjectPane(kind: .processStatus)),
                    .pane(ProjectPane(kind: .lmStudioDashboard)),
                    .pane(ProjectPane(kind: .systemMetrics)),
                ]),
            ]),
        ])
        let project = Project(
            name: "Batty", rootPath: "/Users/test/Batty", color: .violet,
            layout: ProjectLayout(root: nested, preset: nil),
            runStartupCommandsOnOpen: true, approvedCommandsHash: "abc",
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(project)
        #expect(decoded == project)
        #expect(Set(decoded.layout.panes.map(\.kind)) == Set(PaneContentKind.allCases))
        #expect(decoded.paneCount == 5)
        #expect(decoded.tabCount == 2)
        #expect(decoded.startupCommands == [ProjectStartupCommand(paneIndex: 0, tabIndex: 0, command: "npm run dev")])
    }

    @Test func presetPreservesPresetAndRoundTrips() throws {
        let project = Project(name: "A", rootPath: "/tmp/a", layout: .preset(.twoByTwoGrid))
        #expect(try roundTrip(project).layout.preset == .twoByTwoGrid)
    }

    @Test(arguments: PaneLayout.allCases)
    func presetSlotCountMatchesPaneCount(_ preset: PaneLayout) {
        let layout = ProjectLayout.preset(preset)
        #expect(layout.paneCount == preset.paneCount)
        #expect(layout.paneCount == preset.layoutPanes.count)
        #expect(layout.preset == preset)
        #expect(layout.panes.allSatisfy { $0.kind == .terminal && $0.tabs.count == 1 })
    }

    @Test(arguments: PaneLayout.allCases)
    func presetSlotOrderMatchesLayoutPanes(_ preset: PaneLayout) {
        let kinds: [PaneContentKind] = [.gitStatus, .processStatus, .systemMetrics, .lmStudioDashboard]
        let layout = ProjectLayout.preset(preset, kinds: kinds)
        #expect(layout.panes.map(\.kind) == Array(kinds.prefix(preset.paneCount)))
        // Reading the topology's geometry back (equal split per node) must
        // reproduce each layoutPanes frame's reading order.
        let frames = Self.slotFrames(layout.root, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let expected = preset.layoutPanes.map(\.frame)
        #expect(frames.count == expected.count)
        for (got, want) in zip(frames, expected) {
            #expect(abs(got.minX - want.minX) < 1e-9 && abs(got.minY - want.minY) < 1e-9)
            #expect(abs(got.width - want.width) < 1e-9 && abs(got.height - want.height) < 1e-9)
        }
    }

    private static func slotFrames(_ node: ProjectLayoutNode, in rect: CGRect) -> [CGRect] {
        switch node {
        case .pane: return [rect]
        case .split(let direction, let children):
            let n = CGFloat(children.count)
            return children.enumerated().flatMap { index, child -> [CGRect] in
                let i = CGFloat(index)
                let sub = direction == .horizontal
                    ? CGRect(x: rect.minX + rect.width / n * i, y: rect.minY, width: rect.width / n, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + rect.height / n * i, width: rect.width, height: rect.height / n)
                return slotFrames(child, in: sub)
            }
        }
    }

    @Test func resolvesPathsInsideTheRootAndRejectsEscapes() {
        let project = Project(name: "P", rootPath: "/Users/test/proj")
        #expect(project.resolve(".")?.path == "/Users/test/proj")
        #expect(project.resolve("src/app")?.path == "/Users/test/proj/src/app")
        #expect(project.resolve("src/../lib")?.path == "/Users/test/proj/lib")
        #expect(project.resolve("/Users/test/proj/src")?.path == "/Users/test/proj/src")
        #expect(project.resolve("../x") == nil)
        #expect(project.resolve("src/../../x") == nil)
        #expect(project.resolve("/etc") == nil)
        #expect(project.resolve("/Users/test/proj-other") == nil)
    }

    @Test func rootPathIsStandardizedOnInit() {
        #expect(Project(name: "P", rootPath: "/Users/test/./proj/../proj").rootPath == "/Users/test/proj")
    }

    @Test func blankStartupCommandsAreIgnored() {
        let layout = ProjectLayout(root: .pane(.terminal(tabs: [
            ProjectTab(startupCommand: "  "), ProjectTab(startupCommand: ""), ProjectTab(startupCommand: "make"),
        ])))
        let project = Project(name: "P", rootPath: "/tmp/p", layout: layout)
        #expect(project.startupCommands == [ProjectStartupCommand(paneIndex: 0, tabIndex: 2, command: "make")])
    }

    private func decodeProject(_ json: String) throws -> Project {
        try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
    }

    private let validID = "11111111-1111-1111-1111-111111111111"

    private func projectJSON(pane: String, extra: String = "") -> String {
        """
        {"id":"\(validID)","name":"P","rootPath":"/tmp/p",\(extra)
         "layout":{"root":{"type":"pane","pane":\(pane)}}}
        """
    }

    @Test func unknownFutureFieldsAreIgnored() throws {
        let json = projectJSON(pane: #"{"kind":"terminal","tabs":[{"workingDirectory":".","future":1}],"x":2}"#, extra: #""futureField":true,"#)
        #expect(try decodeProject(json).paneCount == 1)
    }

    @Test func unknownKindFailsTheDecode() {
        #expect(throws: DecodingError.self) { try decodeProject(projectJSON(pane: #"{"kind":"hologram"}"#)) }
    }

    @Test func missingKindDoesNotBecomeTerminal() {
        #expect(throws: DecodingError.self) { try decodeProject(projectJSON(pane: #"{"tabs":[]}"#)) }
    }

    @Test func unknownNodeTypeFailsTheDecode() {
        let json = #"{"id":"\#(validID)","name":"P","rootPath":"/tmp/p","layout":{"root":{"type":"tabs"}}}"#
        #expect(throws: DecodingError.self) { try decodeProject(json) }
    }

    @Test func relativeRootResolvesNothingAndFailsDecode() {
        let relative = Project(name: "P", rootPath: "proj")
        #expect(relative.resolve("../../etc") == nil)
        #expect(relative.resolve(".") == nil)
        let json = #"{"id":"\#(validID)","name":"P","rootPath":"proj","layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}}"#
        #expect(throws: DecodingError.self) { try decodeProject(json) }
    }

    @Test func normalizationIsLexicalAndIgnoresTheFilesystem() {
        let project = Project(name: "P", rootPath: "/private/tmp/does-not-exist-\(UUID().uuidString)/./x")
        #expect(project.rootPath.hasPrefix("/private/tmp/does-not-exist-"))
        #expect(project.resolve("a/../b")?.path == project.rootPath + "/b")
        #expect(project.resolve("..") == nil)
    }

    @Test func outOfRangeColorStillLoads() throws {
        let json = #"{"id":"\#(validID)","name":"P","rootPath":"/tmp/p","color":99,"layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}}"#
        #expect(try decodeProject(json).color == .blue)
    }

    @Test func terminalPaneAlwaysHasAtLeastOneTab() throws {
        #expect(ProjectPane(kind: .terminal, tabs: []).tabs == [ProjectTab()])
        #expect(ProjectPane(kind: .gitStatus).tabs.isEmpty)
        for pane in [#"{"kind":"terminal"}"#, #"{"kind":"terminal","tabs":[]}"#] {
            #expect(try decodeProject(projectJSON(pane: pane)).layout.panes[0].tabs == [ProjectTab()])
        }
    }

    @Test func fractionalSecondDatesRoundTripExactly() throws {
        let project = Project(name: "P", rootPath: "/tmp/p", lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(try roundTrip(project).lastOpenedAt == project.lastOpenedAt)
    }

    @Test func wholeSecondDatesStillDecode() throws {
        let json = #"{"id":"\#(validID)","name":"P","rootPath":"/tmp/p","lastOpenedAt":"2023-11-14T22:13:20Z","layout":{"root":{"type":"pane","pane":{"kind":"terminal"}}}}"#
        #expect(try decodeProject(json).lastOpenedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
