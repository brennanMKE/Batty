// HelpCatalog.swift

import Foundation

enum HelpCatalog {
    static let sections: [HelpSection] = [
        .init(id: "01-overview",      title: "Overview",            resourceName: "01-overview"),
        .init(id: "02-sessions",      title: "Sessions",            resourceName: "02-sessions"),
        .init(id: "03-panes",         title: "Panes and Splits",    resourceName: "03-panes"),
        .init(id: "04-tabs",          title: "Tabs",                resourceName: "04-tabs"),
        .init(id: "05-shortcuts",     title: "Keyboard Shortcuts",  resourceName: "05-shortcuts"),
        .init(id: "06-notifications", title: "Notifications",       resourceName: "06-notifications"),
        .init(id: "07-themes",        title: "Themes",              resourceName: "07-themes"),
        .init(id: "08-drag-and-drop", title: "Drag and Drop",       resourceName: "08-drag-and-drop"),
    ]
}
