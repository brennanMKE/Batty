// ProjectEditorQuitTests.swift

import AppKit
import BattyXPCCore
import Foundation
import Testing
@testable import BattyKit

/// Quitting with unsaved Project Editor edits (#0481). Everything goes
/// through `AppStateStore.handleTerminateRequest` and its reply hook, never a
/// real `NSApp.terminate`; windows are real and never shown.
@MainActor
private final class QuitFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-quit-\(UUID().uuidString)")
    let store: AppStateStore
    let model: ProjectEditorViewModel
    let projectID: UUID
    var replies: [Bool] = []
    var events: [String] = []
    var confirmAnswer = true

    init(projects: Bool = true) throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("root"), withIntermediateDirectories: true)
        store = AppStateStore(
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            featureFlags: FeatureFlags(projects: projects),
            projectsFileURL: base.appendingPathComponent("projects.json")
        )
        store.terminateHandler = {}
        let project = Project(name: "Stored", rootPath: base.appendingPathComponent("root").path, color: .violet)
        projectID = project.id
        let projectStore = ProjectStore(fileURL: base.appendingPathComponent("editor-projects.json"))
        try projectStore.upsert(project)
        model = ProjectEditorViewModel(store: projectStore, initialSelection: project.id)
        store.projectEditorModelOverride = { [model] in model }
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func dirty(_ name: String = "Renamed") {
        model.setName(name)
    }

    func quit(promptsEditor: Bool = true) -> NSApplication.TerminateReply {
        store.handleTerminateRequest(
            promptsEditor: promptsEditor,
            confirm: { [unowned self] _ in
                events.append("confirm")
                return confirmAnswer
            },
            reply: { [unowned self] proceed in
                events.append("reply")
                replies.append(proceed)
            }
        )
    }
}

@MainActor
struct ProjectEditorQuitTests {
    @Test func aDirtyEditorProducesAPendingQuestionAndNoReplyYet() throws {
        let f = try QuitFixture()
        f.dirty()

        #expect(f.quit() == .terminateLater)
        #expect(f.model.pendingNavigation == .terminate)
        #expect(f.replies.isEmpty)
        #expect(f.events.isEmpty, "neither the Quit Batty? alert nor a reply may precede the answer")
    }

    @Test func saveStoresTheEditsAndLetsTheQuitContinueThroughTheQuitAlert() throws {
        let f = try QuitFixture()
        f.dirty("Saved Name")
        _ = f.quit()

        f.model.resolveUnsaved(.save)

        #expect(f.replies == [true])
        #expect(f.events == ["confirm", "reply"], "the editor question comes before the Quit Batty? alert")
        #expect(f.model.isDirty == false)
        #expect(f.model.draft?.name == "Saved Name")
        #expect(f.model.pendingNavigation == nil)
    }

    @Test func aSaveThatFailsCancelsTheQuitAndLeavesTheErrorShowing() throws {
        let f = try QuitFixture()
        f.dirty("")
        _ = f.quit()

        f.model.resolveUnsaved(.save)

        #expect(f.replies == [false])
        #expect(f.events == ["reply"], "no Quit Batty? alert after a failed save")
        #expect(f.model.saveError != nil)
        #expect(f.model.isDirty)
        #expect(f.model.pendingNavigation == nil)
    }

    @Test func discardLetsTheQuitContinueWithoutTouchingTheDraft() throws {
        let f = try QuitFixture()
        f.dirty("Unsaved Edit")
        _ = f.quit()

        f.model.resolveUnsaved(.discard)

        #expect(f.replies == [true])
        #expect(f.model.draft?.name == "Unsaved Edit")
        #expect(f.model.isDirty)
    }

    @Test func cancelCancelsTheQuitAndLeavesTheEditorAsItWas() throws {
        let f = try QuitFixture()
        f.dirty("Unsaved Edit")
        _ = f.quit()

        f.model.resolveUnsaved(.cancel)

        #expect(f.replies == [false])
        #expect(f.events == ["reply"])
        #expect(f.model.draft?.name == "Unsaved Edit")
        #expect(f.model.isDirty)
        #expect(f.model.pendingNavigation == nil)
    }

    @Test func decliningTheQuitAlertAfterDiscardCancelsTheQuit() throws {
        let f = try QuitFixture()
        f.dirty()
        f.confirmAnswer = false
        _ = f.quit()

        f.model.resolveUnsaved(.discard)

        #expect(f.events == ["confirm", "reply"])
        #expect(f.replies == [false])
        #expect(f.model.isDirty, "a quit cancelled by the alert must not have thrown the edits away")
    }

    @Test func aSecondQuitRequestCancelsTheFirstAndDismissesTheQuestion() throws {
        let f = try QuitFixture()
        f.dirty()
        f.model.presentForQuit = { [model = f.model] in model.pendingNavigation == nil }
        #expect(f.quit() == .terminateLater)

        #expect(f.quit() == .terminateCancel)
        #expect(f.replies == [false])
        #expect(f.model.pendingNavigation == nil)
        f.model.resolveUnsaved(.discard)
        #expect(f.replies == [false], "nothing is left pending to answer")
    }

    @Test func anotherNavigationReplacingThePendingQuitCancelsIt() throws {
        let f = try QuitFixture()
        f.dirty()
        _ = f.quit()

        f.model.requestNavigation(.closeWindow)

        #expect(f.replies == [false])
        #expect(f.model.pendingNavigation == .closeWindow)
    }

    @Test func closingTheWindowWhileAQuitIsPendingCancelsIt() throws {
        let f = try QuitFixture()
        f.dirty()
        _ = f.quit()

        f.model.abandonQuit()

        #expect(f.replies == [false])
        #expect(f.model.pendingNavigation == nil)
    }

    @Test func aWindowThatCannotShowTheQuestionCancelsTheQuitAtOnce() throws {
        let f = try QuitFixture()
        f.dirty()
        f.model.presentForQuit = { false }

        #expect(f.quit() == .terminateCancel)
        #expect(f.replies.isEmpty, "an immediate answer is the return value, not a reply")
        #expect(f.model.pendingNavigation == nil)
        #expect(f.events.isEmpty)
    }

    @Test func aCleanEditorQuitsNowAfterOnlyTheQuitAlert() throws {
        let f = try QuitFixture()
        #expect(f.model.isDirty == false)

        #expect(f.quit() == .terminateNow)
        #expect(f.events == ["confirm"])
        #expect(f.replies.isEmpty)
        #expect(f.model.pendingNavigation == nil)
    }

    @Test func aCleanEditorStillHonoursACancelledQuitAlert() throws {
        let f = try QuitFixture()
        f.confirmAnswer = false

        #expect(f.quit() == .terminateCancel)
        #expect(f.replies.isEmpty)
    }

    @Test func noEditorQuitsNowAfterOnlyTheQuitAlert() throws {
        let f = try QuitFixture()
        f.store.projectEditorModelOverride = { nil }

        #expect(f.quit() == .terminateNow)
        #expect(f.events == ["confirm"])
        #expect(f.replies.isEmpty)
    }

    @Test func aQuitSkipsTheEditorQuestionWhenToldNotToPrompt() throws {
        let f = try QuitFixture()
        f.dirty("Unsaved Edit")

        #expect(f.quit(promptsEditor: false) == .terminateNow)
        #expect(f.model.pendingNavigation == nil)
        #expect(f.model.draft?.name == "Unsaved Edit")
        #expect(f.quit(promptsEditor: true) == .terminateLater)
    }

    @Test func uiTestModeSkipsTheEditorQuestionUnlessTheOverrideIsSet() {
        let mode = QuitConfirmation.testModeEnvVar
        let override = QuitConfirmation.promptEditorOnQuitEnvVar
        #expect(QuitConfirmation.promptsEditorOnQuit(environment: [:]))
        #expect(QuitConfirmation.promptsEditorOnQuit(environment: [override: "1"]), "the override alone changes nothing outside UI-test mode")
        #expect(!QuitConfirmation.promptsEditorOnQuit(environment: [mode: "1"]))
        #expect(!QuitConfirmation.promptsEditorOnQuit(environment: [mode: "1", override: "0"]))
        #expect(QuitConfirmation.promptsEditorOnQuit(environment: [mode: "1", override: "1"]))
    }

    // MARK: - Flag off

    @Test func withTheFlagOffTheQuitPathNeverReachesTheEditor() throws {
        let f = try QuitFixture(projects: false)
        f.dirty("Unsaved Edit")
        var reads = 0
        f.store.projectEditorModelOverride = {
            reads += 1
            return f.model
        }

        #expect(f.quit() == .terminateNow)
        #expect(f.events == ["confirm"])
        #expect(reads == 0)
        #expect(f.store.holdQuitForUnsavedEditor() == false)
        #expect(reads == 0)
        #expect(f.store.quitWhenEditorCloses == false)
        #expect(f.store.projectStoreIsConstructed == false)
        #expect(ProjectEditorWindowController.shared.window == nil)
        #expect(ProjectEditorWindowController.shared.model == nil)
    }

    // MARK: - Automatic quit when the last content window closes

    @Test func aDirtyEditorKeepsTheAppRunningWhenTheLastContentWindowCloses() throws {
        let f = try QuitFixture()
        f.dirty()

        f.store.removeWindow(id: f.store.windows[0].id)

        #expect(f.store.windows.isEmpty)
        #expect(f.store.terminationIsScheduled == false, "a held quit schedules no deferred terminate")
        #expect(f.store.quitWhenEditorCloses, "the held quit must be remembered for the editor's close")
    }

    @Test func aCleanEditorDoesNotKeepTheAppRunning() async throws {
        let f = try QuitFixture()
        let terminated = await terminationSignal(of: f.store) {
            f.store.removeWindow(id: f.store.windows[0].id)
        }

        #expect(terminated)
        #expect(f.store.quitWhenEditorCloses == false)
    }

    @Test func closingTheEditorAfterAHeldQuitQuits() async throws {
        let f = try QuitFixture()
        f.dirty()
        f.store.terminateHandler = {}
        f.store.removeWindow(id: f.store.windows[0].id)
        #expect(f.store.quitWhenEditorCloses)
        f.model.cancel()
        #expect(f.model.isDirty == false)

        let terminated = await terminationSignal(of: f.store) {
            f.store.projectEditorDidClose()
        }

        #expect(terminated)
        #expect(f.store.quitWhenEditorCloses == false)
    }

    @Test func aContentWindowThatReturnsBeforeTheEditorClosesStopsTheHeldQuit() async throws {
        let f = try QuitFixture()
        f.dirty()
        f.store.removeWindow(id: f.store.windows[0].id)
        #expect(f.store.quitWhenEditorCloses)
        _ = f.store.windowRuntime(for: WindowID())

        f.store.projectEditorDidClose()

        #expect(f.store.quitWhenEditorCloses == false)
        #expect(f.store.terminationIsScheduled == false, "the live window state vetoed the quit before anything was scheduled")
    }

    /// Runs `body` and waits for `terminateHandler` to fire, bounded by
    /// `TestBounds.hangGuard` as a failure guard only.
    private func terminationSignal(of store: AppStateStore, _ body: () -> Void) async -> Bool {
        let lock = NSLock()
        var didResume = false
        var fired = false
        var guardTask: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            func resumeOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }
            store.terminateHandler = {
                fired = true
                resumeOnce()
            }
            body()
            guardTask = Task {
                try? await Task.sleep(for: .seconds(TestBounds.hangGuard))
                resumeOnce()
            }
        }
        guardTask?.cancel()
        return fired
    }
}

@MainActor
struct ProjectEditorCloseItemTests {
    private func window(identifier: String? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return window
    }

    private func sheet() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        return panel
    }

    @Test func theEditorWindowItselfIsClosed() {
        let store = AppStateStore()
        let editor = window(identifier: ProjectEditorWindowController.windowIdentifier)
        var closed: [NSWindow] = []

        #expect(store.closeProjectEditor(from: editor) { closed.append($0) })
        #expect(closed == [editor])
    }

    @Test func aSheetOverTheEditorResolvesToTheEditorAndIsLeftAlone() {
        let store = AppStateStore()
        let editor = window(identifier: ProjectEditorWindowController.windowIdentifier)
        let overEditor = sheet()
        editor.beginSheet(overEditor)
        defer { editor.endSheet(overEditor) }
        var closed: [NSWindow] = []

        #expect(overEditor.sheetParent === editor)
        #expect(AppStateStore.projectEditorWindow(from: overEditor) === editor)
        #expect(store.closeProjectEditor(from: overEditor) { closed.append($0) }, "the editor, not the sheet, owns the chord")
        #expect(closed.isEmpty, "a sheet blocks closing, so the chord does nothing rather than closing the sheet")
    }

    @Test func theEditorWithAnAttachedSheetIsNotClosed() {
        final class SheetedWindow: NSWindow {
            var stub: NSWindow?
            override var attachedSheet: NSWindow? { stub }
        }
        let store = AppStateStore()
        let editor = SheetedWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: true)
        editor.isReleasedWhenClosed = false
        editor.identifier = NSUserInterfaceItemIdentifier(ProjectEditorWindowController.windowIdentifier)
        var closed: [NSWindow] = []
        #expect(store.closeProjectEditor(from: editor) { closed.append($0) })
        #expect(closed == [editor])
        closed = []
        editor.stub = sheet()
        #expect(store.closeProjectEditor(from: editor) { closed.append($0) })
        #expect(closed.isEmpty)
    }

    @Test func otherWindowsAndSheetsOverThemAreNotTheEditor() {
        let store = AppStateStore()
        let settings = window(identifier: "com_apple_SwiftUI_Settings_window")
        let overSettings = sheet()
        settings.beginSheet(overSettings)
        defer { settings.endSheet(overSettings) }
        var closed: [NSWindow] = []

        #expect(!store.closeProjectEditor(from: settings) { closed.append($0) })
        #expect(!store.closeProjectEditor(from: overSettings) { closed.append($0) })
        #expect(!store.closeProjectEditor(from: nil) { closed.append($0) })
        #expect(closed.isEmpty)
    }

    @Test func closeIsEnabledWithNoContentWindowSoTheEditorCanBeClosed() {
        let store = AppStateStore()
        store.terminateHandler = {}
        #expect(store.closeItemIsEnabled, "a content window with a selected Session enables it")

        store.removeWindow(id: store.windows[0].id)

        #expect(store.keyWindowOrFirstRegistered() == nil)
        #expect(store.closeItemIsEnabled)
    }
}

/// The Root, Tab and Git Status repository folder choosers are sheets on the editor window (#0497),
/// so the panel is driven through an injected presenter and never run.
@MainActor
struct ProjectEditorPanelTests {
    private final class Recorder {
        var windows: [NSWindow] = []
        var directories: [URL?] = []
        var completions: [(URL?) -> Void] = []

        var presenter: ProjectEditorPanels.Presenter {
            { [self] panel, window, completion in
                windows.append(window)
                directories.append(panel.directoryURL)
                completions.append(completion)
            }
        }
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func theRootChooserHangsFromTheEditorWindowAndAppliesTheChosenFolderOnCompletion() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        let editor = window()
        let chosen = f.base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let before = f.model.draft?.rootPath

        ProjectEditorPanels.chooseRoot(for: f.model, window: editor, present: recorder.presenter)

        #expect(recorder.windows == [editor])
        #expect(f.model.draft?.rootPath == before, "nothing applies before the panel completes")
        recorder.completions[0](chosen)
        #expect(f.model.draft?.rootPath == Project.standardizedRoot(chosen.path))
    }

    @Test func aCancelledRootChooserLeavesTheEditorAsItWas() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        f.dirty("Unsaved Edit")
        let before = f.model.draft

        ProjectEditorPanels.chooseRoot(for: f.model, window: window(), present: recorder.presenter)
        recorder.completions[0](nil)

        #expect(f.model.draft == before)
        #expect(f.model.draft?.name == "Unsaved Edit")
    }

    @Test func theFolderChooserAppliesToTheTabItWasOpenedFor() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        let inside = f.base.appendingPathComponent("root/web")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let editor = window()

        ProjectEditorPanels.chooseFolder(for: f.model, tab: 0, window: editor, present: recorder.presenter)
        #expect(recorder.windows == [editor])
        #expect(f.model.selectedPane?.tabs[0].workingDirectory != "web", "nothing applies before the panel completes")
        recorder.completions[0](inside)

        #expect(f.model.selectedPane?.tabs[0].workingDirectory == "web")
        #expect(f.model.saveError == nil)
    }

    @Test func theFolderChooserAppliesToTheRepositoryOfAGitStatusPane() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        let inside = f.base.appendingPathComponent("root/repo")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        f.model.setKind(.gitStatus)
        #expect(f.model.selectedPane?.kind == .gitStatus)

        ProjectEditorPanels.chooseFolder(for: f.model, tab: nil, window: window(), present: recorder.presenter)
        recorder.completions[0](inside)

        #expect(f.model.selectedPane?.repositoryPath == "repo")
    }

    @Test func aFolderOutsideTheRootIsRefusedAndAppliesNothing() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        let before = f.model.selectedPane?.tabs[0].workingDirectory

        ProjectEditorPanels.chooseFolder(for: f.model, tab: 0, window: window(), present: recorder.presenter)
        recorder.completions[0](f.base)

        #expect(f.model.saveError != nil)
        #expect(f.model.selectedPane?.tabs[0].workingDirectory == before)
    }

    @Test func noWindowMeansNoPanelAndNoChange() throws {
        let f = try QuitFixture()
        let recorder = Recorder()
        f.dirty("Unsaved Edit")

        ProjectEditorPanels.chooseDirectory(startingAt: nil, message: "m", window: nil, present: recorder.presenter) { _ in
            Issue.record("completion must not run without a panel")
        }

        #expect(recorder.completions.isEmpty)
        #expect(f.model.draft?.name == "Unsaved Edit")
    }
}
