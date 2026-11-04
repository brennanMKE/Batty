// ProjectBackgroundFixture.swift

import BattyXPCCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BattyKit

enum BackgroundTestImage {
    static func encoded(width: Int = 256, height: Int = 256, type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Varied pixels, so the file has real compressed data to damage.
        for x in stride(from: 0, to: width, by: max(width / 64, 1)) {
            for y in stride(from: 0, to: height, by: max(height / 64, 1)) {
                context.setFillColor(red: CGFloat(x % 97) / 97, green: CGFloat(y % 89) / 89, blue: CGFloat((x ^ y) % 83) / 83, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: max(width / 64, 1), height: max(height / 64, 1)))
            }
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return data as Data
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A temporary world: `projects.json`, the Project image folder, and stand-ins
/// for the app-wide and Pane folders. Nothing touches Application Support.
@MainActor
final class ProjectBackgroundFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("batty-project-bg-\(UUID().uuidString)", isDirectory: true)
    let testDefaults = TestDefaults()
    private(set) var inspections = 0
    private(set) lazy var library = ProjectBackgroundLibrary(
        directory: projectFolder,
        adoptableFrom: [appWideFolder, paneFolder],
        inspect: { [unowned self] path in
            inspections += 1
            return TerminalBackgroundImageImporter.inspect(path: path, directory: projectFolder)
        }
    )

    var root: URL { base.appendingPathComponent("root", isDirectory: true) }
    var projectsFile: URL { base.appendingPathComponent("projects.json") }
    var backupFile: URL { base.appendingPathComponent(ProjectStore.backupFileName) }
    var projectFolder: URL { base.appendingPathComponent("ProjectBackgrounds", isDirectory: true) }
    var appWideFolder: URL { base.appendingPathComponent("app-wide", isDirectory: true) }
    var paneFolder: URL { base.appendingPathComponent("pane", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @MainActor deinit {
        testDefaults.tearDown()
        try? FileManager.default.removeItem(at: base)
    }

    func resetInspections() { inspections = 0 }

    func appStore(sessions: [SessionRuntime] = []) -> AppStateStore {
        let store = AppStateStore(
            sessions: sessions,
            nameCache: SessionNameCache(fileURL: base.appendingPathComponent("cache.json")),
            preferences: testDefaults.defaults,
            projectsFileURL: projectsFile,
            backgroundGate: .acceptingEveryImage(defaults: testDefaults.defaults)
        )
        store.projectBackgrounds = library
        return store
    }

    /// A real importer copy. A different `width` gives a different digest folder.
    func copy(in folder: URL? = nil, width: Int = 256, named name: String = "photo.png") async throws -> String {
        let source = base.appendingPathComponent("source-\(UUID().uuidString)-\(name)")
        try BackgroundTestImage.encoded(width: width).write(to: source)
        let importer = TerminalBackgroundImageImporter(directory: folder ?? projectFolder, cleanup: .unreferenced)
        return try await importer.importImage(from: source)
    }

    /// A readable `projects.json` naming no image, so `reclaim` doesn't skip.
    func saveProjectsFile() throws {
        try ProjectStore(fileURL: projectsFile).upsert(project(name: "No Image", background: nil))
    }

    func removeFolder(of path: String) throws {
        try FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    func age(folderOf path: String, byDays days: Double = 2) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 86_400)],
            ofItemAtPath: (path as NSString).deletingLastPathComponent
        )
    }

    func session(_ panes: Int = 1) -> SessionRuntime {
        let gate = AppWideBackgroundGate.acceptingEveryImage(defaults: testDefaults.defaults)
        func pane() -> PaneRuntime {
            PaneRuntime(tabs: [TabRuntime(workingDirectory: root.path, backgroundGate: gate)], tabBackgroundGate: gate)
        }
        guard panes > 1 else { return SessionRuntime(title: "Website", tree: SplitTree(root: .leaf(pane()))) }
        return SessionRuntime(title: "Website", tree: SplitTree(root: .split(id: UUID(), direction: .horizontal, ratio: 0.5, left: .leaf(pane()), right: .leaf(pane()))))
    }

    func project(name: String = "Stored", background: TerminalBackgroundSettings?, layout: ProjectLayout = .preset(.singlePane)) -> Project {
        Project(name: name, rootPath: root.path, color: .teal, layout: layout, background: background)
    }
}

/// Non-default in every field, and different from the app-wide and second values.
func projectBackgroundValue(path: String?) -> TerminalBackgroundSettings {
    TerminalBackgroundSettings(imagePath: path, fit: .cover, position: .topRight, imageOpacity: 0.35, terminalOpacity: 0.6, opacityAffectsCells: true)
}

func secondBackgroundValue(path: String?) -> TerminalBackgroundSettings {
    TerminalBackgroundSettings(imagePath: path, fit: .stretch, position: .bottomLeft, imageOpacity: 0.8, terminalOpacity: 0.45)
}

func appWideBackgroundValue(path: String?) -> TerminalBackgroundSettings {
    TerminalBackgroundSettings(imagePath: path, fit: .none, position: .bottomCenter, imageOpacity: 0.55, terminalOpacity: 0.9)
}

/// With no image, the builder writes only the terminal opacity lines.
func projectBackgroundLines(path: String?) -> [String] {
    let image = path.map {
        ["background-image = \"\($0)\"", "background-image-fit = cover", "background-image-position = top-right", "background-image-opacity = 0.35"]
    }
    return (image ?? []) + ["background-opacity = 0.6", "background-opacity-cells = true"]
}

@MainActor
func backgroundLines(_ tab: TabRuntime) -> [String] {
    tab.terminal.renderedConfig.split(separator: "\n").map(String.init).filter { $0.hasPrefix("background-") }
}
