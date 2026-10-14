// UITestDriver.swift

import AppKit
import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "UITestDriver")

/// Reads `BATTY_UI_TEST_SCRIPT` from the process environment, decodes the
/// JSON intent array, and dispatches each intent sequentially through the
/// same `AppStateStore` paths that real user actions call.
///
/// Gated on env-var presence at runtime — production launches never enter
/// this path. No `#if DEBUG` gate because UI tests run against the Beta build.
@MainActor
public enum UITestDriver {
    public static let scriptEnvVar = "BATTY_UI_TEST_SCRIPT"
    public static let errorSentinelPrefix = "batty-ui-test-driver-error-"
    public static let projectsFileEnvVar = "BATTY_UI_TEST_PROJECTS_FILE"

    /// With "1" alongside the script variable, Sidebar rows append their
    /// icon's SF Symbol name to their accessibility value.
    public static let sidebarIconsEnvVar = "BATTY_UI_TEST_SIDEBAR_ICONS"

    static func exposesSidebarIcons(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[scriptEnvVar] != nil && environment[sidebarIconsEnvVar] == "1"
    }

    /// Where a UI-test launch keeps `projects.json`, so a test never shares
    /// the guest's real store. Honored only alongside the script variable;
    /// an empty or relative path is ignored.
    static func projectsFileOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard environment[scriptEnvVar] != nil,
              let path = environment[projectsFileEnvVar],
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func runIfNeeded(store: AppStateStore) {
        guard let raw = ProcessInfo.processInfo.environment[scriptEnvVar] else { return }
        guard let data = raw.data(using: .utf8) else {
            writeError("BATTY_UI_TEST_SCRIPT is not valid UTF-8")
            return
        }
        let intents: [UITestIntent]
        do {
            intents = try JSONDecoder().decode([UITestIntent].self, from: data)
        } catch {
            writeError("Failed to decode BATTY_UI_TEST_SCRIPT: \(error)")
            return
        }
        logger.info("ui-test: script loaded count=\(intents.count, privacy: .public)")
        for intent in intents {
            dispatch(intent, store: store)
        }
        logger.info("ui-test: script complete")
    }

    // Not `private` — a `@testable import` test exercises intent
    // resolution directly against this production code rather than
    // re-typing it, the same precedent as `ExitDispatcher.focusedTerminalTab`
    // (#0332 N1).
    static func dispatch(_ intent: UITestIntent, store: AppStateStore) {
        logger.info("ui-test: dispatch intent=\(intent.intentName, privacy: .public)")
        switch intent {
        case .createSession(let name):
            store.addSession(title: name)

        case .selectSession(let name):
            guard let session = store.sessions.first(where: { $0.title == name }) else {
                logger.notice("ui-test: selectSession not-found name=\(name, privacy: .public)")
                return
            }
            store.selectedSessionID = session.id

        case .closeSession(let name):
            guard let session = store.sessions.first(where: { $0.title == name }) else {
                logger.notice("ui-test: closeSession not-found name=\(name, privacy: .public)")
                return
            }
            store.removeSession(id: session.id)

        case .renameSession(let from, let to):
            guard let session = store.sessions.first(where: { $0.title == from }) else {
                logger.notice("ui-test: renameSession not-found from=\(from, privacy: .public)")
                return
            }
            store.renameSession(id: session.id, to: to)

        case .applyLayout(let layoutName):
            guard let layout = PaneLayout(rawValue: layoutName) else {
                logger.notice("ui-test: applyLayout unknown layout=\(layoutName, privacy: .public)")
                return
            }
            guard let session = store.selectedSession else {
                logger.notice("ui-test: applyLayout no selected session")
                return
            }
            layout.apply(to: session.tree)

        case .createTab:
            // Kind-gated (#0332): a non-terminal focused pane's `TabRuntime`
            // is a structural placeholder `PaneView` never renders — adding
            // a second one produces an invisible orphan tab, the exact
            // defect class `docs/pane-kinds.md`'s `#0315` note catalogs.
            guard let pane = store.selectedSession?.focusedTerminalPane else {
                logger.notice("ui-test: createTab no focused terminal pane")
                return
            }
            pane.addTab(inheritingCWDFrom: pane.activeTab)

        case .closeActiveTab:
            store.closeFocusedTab()

        case .renameActiveTab(let name):
            // Kind-gated (#0332): writing `titleOverride` on a non-terminal
            // pane's placeholder tab is cosmetic (nothing reads it), but
            // there is no reason for a UI-test intent to touch it at all.
            guard let tab = store.selectedSession?.focusedTerminalPane?.activeTab else {
                logger.notice("ui-test: renameActiveTab no focused terminal tab")
                return
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.titleOverride = trimmed.isEmpty ? nil : trimmed
            logger.info("ui-test: renameActiveTab tab=\(tab.id, privacy: .public) new=\(tab.titleOverride ?? "nil", privacy: .public)")

        case .resetActiveTabTitle:
            guard let tab = store.selectedSession?.focusedTerminalPane?.activeTab else {
                logger.notice("ui-test: resetActiveTabTitle no focused terminal tab")
                return
            }
            logger.info("ui-test: resetActiveTabTitle tab=\(tab.id, privacy: .public)")
            tab.titleOverride = nil

        case .splitHorizontal:
            guard let session = store.selectedSession else {
                logger.notice("ui-test: splitHorizontal no selected session")
                return
            }
            let pane = session.focusedPaneAnyKind
            session.tree.splitFocusedPane(direction: .horizontal, inheritingFrom: pane)

        case .splitVertical:
            guard let session = store.selectedSession else {
                logger.notice("ui-test: splitVertical no selected session")
                return
            }
            let pane = session.focusedPaneAnyKind
            session.tree.splitFocusedPane(direction: .vertical, inheritingFrom: pane)

        case .createPane(let kind):
            guard let kind = PaneContentKind(rawValue: kind) else {
                logger.notice("ui-test: createPane unknown kind=\(kind, privacy: .public)")
                return
            }
            guard let paneID = store.focusedPaneIDFallback() else {
                logger.notice("ui-test: createPane no focused pane")
                return
            }
            _ = store.splitPane(id: paneID, direction: .horizontal, kind: kind)

        case .focusPane(let index):
            guard let session = store.selectedSession else {
                logger.notice("ui-test: focusPane no selected session")
                return
            }
            let panes = session.tree.allPanes
            guard panes.indices.contains(index) else {
                logger.notice("ui-test: focusPane index=\(index, privacy: .public) out-of-range count=\(panes.count, privacy: .public)")
                return
            }
            store.focusPane(id: panes[index].id)

        case .swapPanes(let a, let b):
            guard let session = store.selectedSession else {
                logger.notice("ui-test: swapPanes no selected session")
                return
            }
            let panes = session.tree.allPanes
            guard panes.indices.contains(a), panes.indices.contains(b) else {
                logger.notice("ui-test: swapPanes index out-of-range a=\(a, privacy: .public) b=\(b, privacy: .public) count=\(panes.count, privacy: .public)")
                return
            }
            logger.info("ui-test: swapPanes a=\(panes[a].id, privacy: .public) b=\(panes[b].id, privacy: .public)")
            session.tree.swapPanes(id: panes[a].id, with: panes[b].id)

        case .applyTheme(let name):
            guard let theme = BattyThemeCatalog.theme(named: name) else {
                logger.notice("ui-test: applyTheme not-found name=\(name, privacy: .public)")
                return
            }
            let key = ThemePreference.defaultsKey(isDark: NSApp.effectiveAppearance.isDark)
            UserDefaults.standard.set(name, forKey: key)
            store.applyThemeToAllSurfaces(theme)

        case .applyThemeToActiveSession(let name):
            guard let theme = BattyThemeCatalog.theme(named: name) else {
                logger.notice("ui-test: applyThemeToActiveSession not-found name=\(name, privacy: .public)")
                return
            }
            guard let session = store.selectedSession else {
                logger.notice("ui-test: applyThemeToActiveSession no selected session")
                return
            }
            store.applyTheme(theme, to: session)

        case .beginPaneSwapDrag(let paneIndex):
            guard let session = store.selectedSession else {
                logger.notice("ui-test: beginPaneSwapDrag no selected session")
                return
            }
            let panes = session.tree.allPanes
            guard panes.indices.contains(paneIndex) else {
                logger.notice("ui-test: beginPaneSwapDrag index=\(paneIndex, privacy: .public) out-of-range count=\(panes.count, privacy: .public)")
                return
            }
            logger.info("ui-test: beginPaneSwapDrag pane=\(panes[paneIndex].id, privacy: .public)")
            PaneSwapDragState.shared.startDrag(from: panes[paneIndex].id)

        case .endPaneSwapDrag:
            logger.info("ui-test: endPaneSwapDrag")
            PaneSwapDragState.shared.endDrag(trigger: .startDragReplaced)

        case .dropFileURLs(let urls, let paneIndex):
            guard let session = store.selectedSession else {
                logger.notice("ui-test: dropFileURLs no selected session")
                return
            }
            let panes = session.tree.allPanes
            guard panes.indices.contains(paneIndex) else {
                logger.notice("ui-test: dropFileURLs index=\(paneIndex, privacy: .public) out-of-range count=\(panes.count, privacy: .public)")
                return
            }
            guard let tab = panes[paneIndex].activeTab else {
                logger.notice("ui-test: dropFileURLs no active tab at index=\(paneIndex, privacy: .public)")
                return
            }
            let joined = ShellQuote.joinPaths(urls)
            tab.terminal.send(joined)
            logger.info("ui-test: dropFileURLs tab=\(tab.id, privacy: .public) count=\(urls.count, privacy: .public) joinedLen=\(joined.count, privacy: .public)")

        case .seedProject(let json):
            let projectStore = store.projectStore
            do {
                let project = try ProjectsFile.decoder.decode(Project.self, from: Data(json.utf8))
                try projectStore.upsert(project)
                logger.info("ui-test: seedProject id=\(project.id, privacy: .public)")
            } catch {
                logger.error("ui-test: seedProject failed error=\(String(describing: error), privacy: .public)")
            }

        case .openProject(let name, let modeName):
            let projectStore = store.projectStore
            guard let project = projectStore.project(named: name) else {
                logger.notice("ui-test: openProject not-found name=\(name, privacy: .public)")
                return
            }
            let mode: AppStateStore.ProjectOpenMode
            switch modeName {
            case nil, "focusExistingOrOpen": mode = .focusExistingOrOpen
            case "openNew": mode = .openNew
            default:
                logger.notice("ui-test: openProject unknown mode=\(modeName ?? "", privacy: .public)")
                return
            }
            do {
                let result = try store.openProject(id: project.id, mode: mode)
                logger.info("ui-test: openProject session=\(result.session.id, privacy: .public) created=\(result.wasCreated, privacy: .public)")
            } catch {
                logger.error("ui-test: openProject failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func writeError(_ message: String) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(errorSentinelPrefix)\(UUID().uuidString)")
        try? message.write(toFile: path, atomically: true, encoding: .utf8)
        logger.error("ui-test: error path=\(path, privacy: .public) message=\(message, privacy: .public)")
    }
}

// MARK: - Intent model

public enum UITestIntent: Decodable, Sendable {
    case createSession(name: String?)
    case selectSession(name: String)
    case closeSession(name: String)
    case renameSession(from: String, to: String)
    case applyLayout(layout: String)
    case createTab
    case closeActiveTab
    case renameActiveTab(to: String)
    case resetActiveTabTitle
    case splitHorizontal
    case splitVertical
    case createPane(kind: String)
    case focusPane(at: Int)
    case swapPanes(at: Int, with: Int)
    case applyTheme(name: String)
    case applyThemeToActiveSession(name: String)
    case beginPaneSwapDrag(at: Int)
    case endPaneSwapDrag
    case dropFileURLs(urls: [String], ontoPaneAt: Int)
    case seedProject(json: String)
    case openProject(name: String, mode: String?)

    var intentName: String {
        switch self {
        case .createSession: return "createSession"
        case .selectSession: return "selectSession"
        case .closeSession: return "closeSession"
        case .renameSession: return "renameSession"
        case .applyLayout: return "applyLayout"
        case .createTab: return "createTab"
        case .closeActiveTab: return "closeActiveTab"
        case .renameActiveTab: return "renameActiveTab"
        case .resetActiveTabTitle: return "resetActiveTabTitle"
        case .splitHorizontal: return "splitHorizontal"
        case .splitVertical: return "splitVertical"
        case .createPane: return "createPane"
        case .focusPane: return "focusPane"
        case .swapPanes: return "swapPanes"
        case .applyTheme: return "applyTheme"
        case .applyThemeToActiveSession: return "applyThemeToActiveSession"
        case .beginPaneSwapDrag: return "beginPaneSwapDrag"
        case .endPaneSwapDrag: return "endPaneSwapDrag"
        case .dropFileURLs: return "dropFileURLs"
        case .seedProject: return "seedProject"
        case .openProject: return "openProject"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case intent, name, layout, kind, from, to, at, with, urls, ontoPaneAt, json, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let intent = try c.decode(String.self, forKey: .intent)
        switch intent {
        case "createSession":
            self = .createSession(name: try c.decodeIfPresent(String.self, forKey: .name))
        case "selectSession":
            self = .selectSession(name: try c.decode(String.self, forKey: .name))
        case "closeSession":
            self = .closeSession(name: try c.decode(String.self, forKey: .name))
        case "renameSession":
            self = .renameSession(
                from: try c.decode(String.self, forKey: .from),
                to: try c.decode(String.self, forKey: .to)
            )
        case "applyLayout":
            self = .applyLayout(layout: try c.decode(String.self, forKey: .layout))
        case "createTab":
            self = .createTab
        case "closeActiveTab":
            self = .closeActiveTab
        case "renameActiveTab":
            self = .renameActiveTab(to: try c.decode(String.self, forKey: .to))
        case "resetActiveTabTitle":
            self = .resetActiveTabTitle
        case "splitHorizontal":
            self = .splitHorizontal
        case "splitVertical":
            self = .splitVertical
        case "createPane":
            self = .createPane(kind: try c.decode(String.self, forKey: .kind))
        case "focusPane":
            self = .focusPane(at: try c.decode(Int.self, forKey: .at))
        case "swapPanes":
            self = .swapPanes(at: try c.decode(Int.self, forKey: .at), with: try c.decode(Int.self, forKey: .with))
        case "applyTheme":
            self = .applyTheme(name: try c.decode(String.self, forKey: .name))
        case "applyThemeToActiveSession":
            self = .applyThemeToActiveSession(name: try c.decode(String.self, forKey: .name))
        case "beginPaneSwapDrag":
            self = .beginPaneSwapDrag(at: try c.decode(Int.self, forKey: .at))
        case "endPaneSwapDrag":
            self = .endPaneSwapDrag
        case "dropFileURLs":
            self = .dropFileURLs(
                urls: try c.decode([String].self, forKey: .urls),
                ontoPaneAt: try c.decode(Int.self, forKey: .ontoPaneAt)
            )
        case "seedProject":
            self = .seedProject(json: try c.decode(String.self, forKey: .json))
        case "openProject":
            self = .openProject(
                name: try c.decode(String.self, forKey: .name),
                mode: try c.decodeIfPresent(String.self, forKey: .mode)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .intent, in: c, debugDescription: "Unknown intent: \(intent)")
        }
    }
}
