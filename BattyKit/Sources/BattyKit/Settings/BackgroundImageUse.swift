// BackgroundImageUse.swift

import Foundation

/// One thing on this Mac that shows a background image.
nonisolated enum BackgroundImageUse: Hashable, Sendable {
    case appWide
    case project(id: UUID, name: String, isShared: Bool)
    case projectDraft
    case session(id: UUID, title: String)
    case pane(id: UUID, sessionTitle: String)
    case tab(id: UUID, sessionTitle: String)

    var localizedDescription: String {
        switch self {
        case .appWide:
            return String(localized: "App default", comment: "Background Images: an image is the app-wide default")
        case .project(_, let name, false):
            return String(localized: "Project \(name)", comment: "Background Images: an image is used by this Project")
        case .project(_, let name, true):
            return String(localized: "Project \(name) (this Mac only)", comment: "Background Images: an image is used by this Shared Project; removing it changes this Mac only")
        case .projectDraft:
            return String(localized: "The Project being edited", comment: "Background Images: an image is used by the Project Editor's unsaved draft")
        case .session(_, let title):
            return String(localized: "Session \(title)", comment: "Background Images: an image is used by this Session")
        case .pane(_, let sessionTitle):
            return String(localized: "A Pane in \(sessionTitle)", comment: "Background Images: an image is used by a Pane in this Session")
        case .tab(_, let sessionTitle):
            return String(localized: "A Tab in \(sessionTitle)", comment: "Background Images: an image is used by a Tab in this Session")
        }
    }

    /// "1 Project and 2 Panes", or nil when there are none.
    static func summary(of uses: [BackgroundImageUse]) -> String? {
        var appWide = 0, projects = 0, sessions = 0, panes = 0, tabs = 0
        for use in uses {
            switch use {
            case .appWide: appWide += 1
            case .project, .projectDraft: projects += 1
            case .session: sessions += 1
            case .pane: panes += 1
            case .tab: tabs += 1
            }
        }
        var parts: [String] = []
        if appWide > 0 { parts.append(String(localized: "the app default", comment: "Background Images: part of a removal summary")) }
        if projects > 0 {
            parts.append(projects == 1
                ? String(localized: "1 Project", comment: "Background Images: part of a removal summary")
                : String(localized: "\(projects) Projects", comment: "Background Images: part of a removal summary"))
        }
        if sessions > 0 {
            parts.append(sessions == 1
                ? String(localized: "1 Session", comment: "Background Images: part of a removal summary")
                : String(localized: "\(sessions) Sessions", comment: "Background Images: part of a removal summary"))
        }
        if panes > 0 {
            parts.append(panes == 1
                ? String(localized: "1 Pane", comment: "Background Images: part of a removal summary")
                : String(localized: "\(panes) Panes", comment: "Background Images: part of a removal summary"))
        }
        if tabs > 0 {
            parts.append(tabs == 1
                ? String(localized: "1 Tab", comment: "Background Images: part of a removal summary")
                : String(localized: "\(tabs) Tabs", comment: "Background Images: part of a removal summary"))
        }
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }
}
