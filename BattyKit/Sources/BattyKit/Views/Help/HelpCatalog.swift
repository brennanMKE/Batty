// HelpCatalog.swift

import Foundation

enum HelpCatalog {
    static let sections: [HelpSection] = [
        .init(id: "01-overview",      title: String(localized: "Overview"),           resourceName: "01-overview"),
        .init(id: "02-sessions",      title: String(localized: "Sessions"),           resourceName: "02-sessions"),
        .init(id: "03-panes",         title: String(localized: "Panes and Splits"),   resourceName: "03-panes"),
        .init(id: "04-tabs",          title: String(localized: "Tabs"),               resourceName: "04-tabs"),
        .init(id: "05-shortcuts",     title: String(localized: "Keyboard Shortcuts"), resourceName: "05-shortcuts"),
        .init(id: "06-notifications", title: String(localized: "Notifications"),      resourceName: "06-notifications"),
        .init(id: "07-themes",        title: String(localized: "Themes"),             resourceName: "07-themes"),
        .init(id: "08-drag-and-drop", title: String(localized: "Drag and Drop"),      resourceName: "08-drag-and-drop"),
    ]
}
