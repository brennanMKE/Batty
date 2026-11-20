// ProjectLayoutDocumentTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

struct ProjectLayoutDocumentTests {
    private func parse(_ json: String) throws(ProjectLayoutDocumentError) -> ProjectLayoutDocument {
        try ProjectLayoutDocument.parse(Data(json.utf8))
    }

    private func error(_ json: String) -> ProjectLayoutDocumentError? {
        do { _ = try parse(json); return nil } catch { return error }
    }

    @Test func decodesAPresetWithPanes() throws {
        let doc = try parse("""
        {"preset":"mainLeftTwoRight","panes":[
          {"kind":"terminal","tabs":[{"title":"server","cwd":"web","command":"npm run dev"},{"cwd":"."}],
           "background":{"id":"https://example.invalid/a.png","opacity":20}},
          {"kind":"git-status","repository":"."},
          {"kind":"process-status"}],"focusedPane":0}
        """)
        #expect(doc.preset == "mainLeftTwoRight")
        #expect(doc.panes?.count == 3)
        #expect(doc.panes?[0].tabs?[0].command == "npm run dev")
        #expect(doc.panes?[0].background?.opacity == 20)
        #expect(doc.panes?[1].repository == ".")
        #expect(doc.focusedPane == 0)
    }

    @Test func decodesARootTree() throws {
        let doc = try parse("""
        {"root":{"split":"horizontal","children":[{"kind":"terminal"},
          {"split":"vertical","children":[{"kind":"terminal"},{"kind":"git-status"}]}]}}
        """)
        guard case .split(let direction, let children)? = doc.root else { Issue.record("no split"); return }
        #expect(direction == "horizontal")
        #expect(children.count == 2)
        guard case .split(_, let inner) = children[1] else { Issue.record("no inner split"); return }
        #expect(inner == [.pane(.init(kind: "terminal")), .pane(.init(kind: "git-status"))])
    }

    @Test func rejectsAnUnknownKeyNamingItsPath() {
        let e = error(#"{"preset":"singlePane","panes":[{"kind":"terminal","tabs":[{"comand":"ls"}]}]}"#)
        #expect(e == .unknownKey(path: "panes[0].tabs[0]", key: "comand"))
        #expect(e?.message == "panes[0].tabs[0].comand: unknown key")
        #expect(error(#"{"preset":"singlePane","extra":1}"#)?.message == "extra: unknown key")
    }

    @Test func rejectsAnUnknownKeyInABackground() {
        let e = error(#"{"preset":"singlePane","panes":[{"kind":"terminal","background":{"opactiy":3}}]}"#)
        #expect(e == .unknownKey(path: "panes[0].background", key: "opactiy"))
    }

    @Test func rejectsBothPresetAndRoot() {
        #expect(error(#"{"preset":"singlePane","root":{"kind":"terminal"}}"#) == .presetAndRoot)
    }

    @Test func rejectsNeither() {
        #expect(error(#"{"focusedPane":0}"#) == .presetAndRoot)
    }

    @Test func rejectsPanesWithoutPreset() {
        #expect(error(#"{"panes":[{"kind":"terminal"}]}"#) == .panesWithoutPreset)
        #expect(error(#"{"panes":[],"root":{"kind":"terminal"}}"#) == .panesWithRoot)
    }

    @Test func rejectsASplitWithOneChild() {
        #expect(error(#"{"root":{"split":"vertical","children":[{"kind":"terminal"}]}}"#) == .splitNeedsTwoChildren(path: "root"))
    }

    @Test func wrongTypeNamesThePath() {
        #expect(error(#"{"preset":"singlePane","panes":[{"kind":"terminal","tabs":[{"cwd":3}]}]}"#) == .wrongType(path: "panes[0].tabs[0].cwd"))
        #expect(error("not json") == .invalidJSON)
    }

    @Test func resolvingFilesMakesRelativeFilesAbsolute() {
        let doc = ProjectLayoutDocument(preset: "singlePane", panes: [
            .init(kind: "terminal", tabs: [.init(background: .init(file: "img/b.png"))], background: .init(file: "a.png")),
        ])
        let fixed = doc.resolvingFiles(against: "/work/dir")
        #expect(fixed.panes?[0].background?.file == "/work/dir/a.png")
        #expect(fixed.panes?[0].tabs?[0].background?.file == "/work/dir/img/b.png")
        let rooted = ProjectLayoutDocument(root: .pane(.init(kind: "terminal", background: .init(file: "/abs/c.png"))))
        #expect(rooted.resolvingFiles(against: "/x").root == rooted.root)
    }

    @Test func requestRoundTripsThroughJSON() throws {
        let layouts: [ProjectWriteRequest.LayoutSource] = [
            .preset("twoByTwoGrid"),
            .document(.init(root: .split(direction: "horizontal", children: [.pane(.init(kind: "terminal")), .pane(.init(kind: "git-status"))]))),
            .fromSession(UUID()), .fromSession(nil),
        ]
        let backgrounds: [ProjectWriteRequest.BackgroundChoice] = [
            .hosted(set: "Deep Space", title: "Nebula"), .hostedID("https://example.invalid/a.png"),
            .myImage(digest: "abc"), .file("/tmp/x.png"), .none,
        ]
        for layout in layouts {
            for background in backgrounds {
                let request = ProjectWriteRequest(
                    target: "Demo", name: "N", rootPath: "/r", color: "green", themeDark: "Batty Dark",
                    layout: layout, background: background, imageOpacityPercent: 20, startupCommands: ["ls"], callerSessionID: UUID())
                let data = try JSONEncoder().encode(request)
                #expect(try JSONDecoder().decode(ProjectWriteRequest.self, from: data) == request)
            }
        }
    }
}

@MainActor
struct ProjectVocabularyTests {
    @Test func presetNamesMatchPaneLayout() {
        #expect(ProjectVocabulary.presetNames == PaneLayout.allCases.map(\.rawValue))
    }

    @Test func colorNamesMatchSessionColor() {
        #expect(ProjectVocabulary.colorNames == SessionColor.allCases.map { "\($0)" })
    }

    @Test func symbolNamesMatchProjectSymbol() {
        #expect(ProjectVocabulary.symbolNames == ProjectSymbol.allCases.map(\.rawValue))
    }
}
