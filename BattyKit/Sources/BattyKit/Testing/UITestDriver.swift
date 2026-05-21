// UITestDriver.swift

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

    private static func dispatch(_ intent: UITestIntent, store: AppStateStore) {
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
            guard let pane = store.selectedSession?.focusedPane else {
                logger.notice("ui-test: createTab no focused pane")
                return
            }
            pane.addTab(inheritingCWDFrom: pane.activeTab)

        case .closeActiveTab:
            store.closeFocusedTab()

        case .renameActiveTab(let name):
            guard let tab = store.selectedSession?.focusedPane.activeTab else {
                logger.notice("ui-test: renameActiveTab no active tab")
                return
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.titleOverride = trimmed.isEmpty ? nil : trimmed
            logger.info("ui-test: renameActiveTab tab=\(tab.id, privacy: .public) new=\(tab.titleOverride ?? "nil", privacy: .public)")

        case .resetActiveTabTitle:
            guard let tab = store.selectedSession?.focusedPane.activeTab else {
                logger.notice("ui-test: resetActiveTabTitle no active tab")
                return
            }
            logger.info("ui-test: resetActiveTabTitle tab=\(tab.id, privacy: .public)")
            tab.titleOverride = nil

        case .splitHorizontal:
            guard let session = store.selectedSession else {
                logger.notice("ui-test: splitHorizontal no selected session")
                return
            }
            let pane = session.focusedPane
            session.tree.splitFocusedPane(direction: .horizontal, inheritingFrom: pane)

        case .splitVertical:
            guard let session = store.selectedSession else {
                logger.notice("ui-test: splitVertical no selected session")
                return
            }
            let pane = session.focusedPane
            session.tree.splitFocusedPane(direction: .vertical, inheritingFrom: pane)

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
            guard let theme = GhosttyThemeCatalog.theme(named: name) else {
                logger.notice("ui-test: applyTheme not-found name=\(name, privacy: .public)")
                return
            }
            UserDefaults.standard.set(name, forKey: ThemePreference.defaultsKey)
            store.applyThemeToAllSurfaces(theme)

        case .applyThemeToActiveSession(let name):
            guard let theme = GhosttyThemeCatalog.theme(named: name) else {
                logger.notice("ui-test: applyThemeToActiveSession not-found name=\(name, privacy: .public)")
                return
            }
            guard let session = store.selectedSession else {
                logger.notice("ui-test: applyThemeToActiveSession no selected session")
                return
            }
            store.applyTheme(theme, to: session)

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
    case focusPane(at: Int)
    case swapPanes(at: Int, with: Int)
    case applyTheme(name: String)
    case applyThemeToActiveSession(name: String)
    case dropFileURLs(urls: [String], ontoPaneAt: Int)

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
        case .focusPane: return "focusPane"
        case .swapPanes: return "swapPanes"
        case .applyTheme: return "applyTheme"
        case .applyThemeToActiveSession: return "applyThemeToActiveSession"
        case .dropFileURLs: return "dropFileURLs"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case intent, name, layout, from, to, at, with, urls, ontoPaneAt
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
        case "focusPane":
            self = .focusPane(at: try c.decode(Int.self, forKey: .at))
        case "swapPanes":
            self = .swapPanes(at: try c.decode(Int.self, forKey: .at), with: try c.decode(Int.self, forKey: .with))
        case "applyTheme":
            self = .applyTheme(name: try c.decode(String.self, forKey: .name))
        case "applyThemeToActiveSession":
            self = .applyThemeToActiveSession(name: try c.decode(String.self, forKey: .name))
        case "dropFileURLs":
            self = .dropFileURLs(
                urls: try c.decode([String].self, forKey: .urls),
                ontoPaneAt: try c.decode(Int.self, forKey: .ontoPaneAt)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .intent, in: c, debugDescription: "Unknown intent: \(intent)")
        }
    }
}
