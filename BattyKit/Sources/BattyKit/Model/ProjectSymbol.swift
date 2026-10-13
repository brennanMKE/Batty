// ProjectSymbol.swift

import AppKit

/// The curated set of 36 SF Symbols a Project can carry, shown on its
/// Sessions' Sidebar rows, the picker cards, the File menu and the Project
/// Editor. Append-only, like `SessionColor`: the raw value is persisted in
/// `projects.json` and is a stable key, not the SF Symbol name, so
/// `systemName` can change without migrating stored data. Never reorder,
/// rename or remove a case. The Symbol picker shows cases in declaration
/// order.
///
/// Symbol and first macOS release that ships it (from the system's
/// `CoreGlyphs` availability table); the deployment target is 15.6:
///
/// - `folder`: `folder.fill`, macOS 10.15
/// - `terminal`: `terminal.fill`, macOS 11.0
/// - `code`: `chevron.left.forwardslash.chevron.right`, macOS 12.0
/// - `hammer`: `hammer.fill`, macOS 10.15
/// - `tools`: `wrench.and.screwdriver.fill`, macOS 11.0
/// - `package`: `shippingbox.fill`, macOS 11.0
/// - `branch`: `arrow.triangle.branch`, macOS 11.0
/// - `checklist`: `checklist`, macOS 12.0
/// - `extension`: `puzzlepiece.extension.fill`, macOS 12.0
/// - `macApp`: `macwindow`, macOS 10.15
/// - `iPhoneApp`: `iphone`, macOS 11.0
/// - `web`: `globe`, macOS 10.15
/// - `server`: `server.rack`, macOS 11.0
/// - `cloud`: `cloud.fill`, macOS 10.15
/// - `network`: `network`, macOS 11.0
/// - `security`: `lock.shield.fill`, macOS 10.15
/// - `link`: `link`, macOS 10.15
/// - `qrCode`: `qrcode`, macOS 10.15
/// - `chip`: `cpu.fill`, macOS 12.0
/// - `wireless`: `antenna.radiowaves.left.and.right`, macOS 10.15
/// - `light`: `lightbulb.fill`, macOS 10.15
/// - `home`: `house.fill`, macOS 10.15
/// - `art`: `paintpalette.fill`, macOS 11.0
/// - `grid`: `square.grid.3x3.fill`, macOS 11.0
/// - `craft`: `scissors`, macOS 10.15
/// - `video`: `film.fill`, macOS 10.15
/// - `game`: `gamecontroller.fill`, macOS 10.15
/// - `document`: `doc.text.fill`, macOS 10.15
/// - `learning`: `books.vertical.fill`, macOS 11.0
/// - `chart`: `chart.bar.fill`, macOS 10.15
/// - `calendar`: `calendar`, macOS 10.15
/// - `social`: `bubble.left.and.bubble.right.fill`, macOS 10.15
/// - `community`: `person.3.fill`, macOS 10.15
/// - `ai`: `sparkles`, macOS 10.15
/// - `model`: `brain`, macOS 12.0
/// - `map`: `map.fill`, macOS 10.15
public enum ProjectSymbol: String, CaseIterable, Codable, Sendable, Hashable {
    case folder
    case terminal
    case code
    case hammer
    case tools
    case package
    case branch
    case checklist
    case `extension`
    case macApp
    case iPhoneApp
    case web
    case server
    case cloud
    case network
    case security
    case link
    case qrCode
    case chip
    case wireless
    case light
    case home
    case art
    case grid
    case craft
    case video
    case game
    case document
    case learning
    case chart
    case calendar
    case social
    case community
    case ai
    case model
    case map

    public static let `default`: ProjectSymbol = .folder

    public var systemName: String {
        switch self {
        case .folder: "folder.fill"
        case .terminal: "terminal.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .hammer: "hammer.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .package: "shippingbox.fill"
        case .branch: "arrow.triangle.branch"
        case .checklist: "checklist"
        case .extension: "puzzlepiece.extension.fill"
        case .macApp: "macwindow"
        case .iPhoneApp: "iphone"
        case .web: "globe"
        case .server: "server.rack"
        case .cloud: "cloud.fill"
        case .network: "network"
        case .security: "lock.shield.fill"
        case .link: "link"
        case .qrCode: "qrcode"
        case .chip: "cpu.fill"
        case .wireless: "antenna.radiowaves.left.and.right"
        case .light: "lightbulb.fill"
        case .home: "house.fill"
        case .art: "paintpalette.fill"
        case .grid: "square.grid.3x3.fill"
        case .craft: "scissors"
        case .video: "film.fill"
        case .game: "gamecontroller.fill"
        case .document: "doc.text.fill"
        case .learning: "books.vertical.fill"
        case .chart: "chart.bar.fill"
        case .calendar: "calendar"
        case .social: "bubble.left.and.bubble.right.fill"
        case .community: "person.3.fill"
        case .ai: "sparkles"
        case .model: "brain"
        case .map: "map.fill"
        }
    }

    public var displayName: String {
        switch self {
        case .folder: String(localized: "Folder", comment: "Project symbol name")
        case .terminal: String(localized: "Terminal", comment: "Project symbol name")
        case .code: String(localized: "Code", comment: "Project symbol name")
        case .hammer: String(localized: "Hammer", comment: "Project symbol name")
        case .tools: String(localized: "Tools", comment: "Project symbol name")
        case .package: String(localized: "Package", comment: "Project symbol name")
        case .branch: String(localized: "Branch", comment: "Project symbol name")
        case .checklist: String(localized: "Checklist", comment: "Project symbol name")
        case .extension: String(localized: "Extension", comment: "Project symbol name")
        case .macApp: String(localized: "Mac App", comment: "Project symbol name")
        case .iPhoneApp: String(localized: "iPhone App", comment: "Project symbol name")
        case .web: String(localized: "Website", comment: "Project symbol name")
        case .server: String(localized: "Server Rack", comment: "Project symbol name")
        case .cloud: String(localized: "Cloud", comment: "Project symbol name")
        case .network: String(localized: "Network", comment: "Project symbol name")
        case .security: String(localized: "Security", comment: "Project symbol name")
        case .link: String(localized: "Link", comment: "Project symbol name")
        case .qrCode: String(localized: "QR Code", comment: "Project symbol name")
        case .chip: String(localized: "Chip", comment: "Project symbol name")
        case .wireless: String(localized: "Wireless", comment: "Project symbol name")
        case .light: String(localized: "Light", comment: "Project symbol name")
        case .home: String(localized: "Home", comment: "Project symbol name")
        case .art: String(localized: "Art", comment: "Project symbol name")
        case .grid: String(localized: "Grid", comment: "Project symbol name")
        case .craft: String(localized: "Craft", comment: "Project symbol name")
        case .video: String(localized: "Video", comment: "Project symbol name")
        case .game: String(localized: "Game", comment: "Project symbol name")
        case .document: String(localized: "Document", comment: "Project symbol name")
        case .learning: String(localized: "Learning", comment: "Project symbol name")
        case .chart: String(localized: "Chart", comment: "Project symbol name")
        case .calendar: String(localized: "Calendar", comment: "Project symbol name")
        case .social: String(localized: "Social", comment: "Project symbol name")
        case .community: String(localized: "Community", comment: "Project symbol name")
        case .ai: String(localized: "AI", comment: "Project symbol name")
        case .model: String(localized: "Model", comment: "Project symbol name")
        case .map: String(localized: "Map", comment: "Project symbol name")
        }
    }

    /// The SF Symbol to draw. Falls back to the default's when this OS no
    /// longer ships `systemName`, so a row never draws an empty image.
    public var resolvedSystemName: String {
        Self.available.contains(self) ? systemName : Self.default.systemName
    }

    private static let available: Set<ProjectSymbol> = Set(allCases.filter { exists($0.systemName) })

    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
