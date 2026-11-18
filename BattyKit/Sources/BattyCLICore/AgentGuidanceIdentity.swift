// AgentGuidanceIdentity.swift

import Foundation

/// Which Batty variant's guidance is being installed, and every name derived
/// from that, so Prod and Beta installs never collide.
public nonisolated struct AgentGuidanceIdentity: Sendable, Equatable {
    public let isBeta: Bool
    /// The variant's bundled `Contents/Resources/bin/batty`, never the `PATH` symlink.
    public let cliExecutablePath: String
    public let version: String
    /// `Contents/Resources/AgentGuidance/`.
    public let guidanceRoot: URL

    public init(isBeta: Bool, cliExecutablePath: String, version: String, guidanceRoot: URL) {
        self.isBeta = isBeta
        self.cliExecutablePath = cliExecutablePath
        self.version = version
        self.guidanceRoot = guidanceRoot
    }

    public static let skillName = "batty-cli"

    public var pluginName: String { isBeta ? "batty-beta" : "batty" }
    public var marketplaceName: String { "\(pluginName)-local" }
    public var cliCommandName: String { pluginName }
    /// Skill folder name for hosts other than Claude Code, which has no plugin namespace.
    public var hostSkillDirectoryName: String { isBeta ? "batty-beta-cli" : Self.skillName }
    /// Matches `SessionNameCache.resolvedDirectoryName`.
    public var appSupportDirectoryName: String { isBeta ? "Batty Beta" : "Batty" }
    public var skillSourceDirectory: URL {
        guidanceRoot.appending(path: "skills/\(Self.skillName)", directoryHint: .isDirectory)
    }

    /// `executableURL` is the CLI at `<App>.app/Contents/Resources/bin/batty`.
    /// Nil outside an app bundle (for example a `swift build` binary).
    public static func fromBundledCLI(executableURL: URL, isBeta: Bool, fileManager: FileManager = .default) -> AgentGuidanceIdentity? {
        let executable = executableURL.resolvingSymlinksInPath()
        let contents = executable
            .deletingLastPathComponent()  // bin/
            .deletingLastPathComponent()  // Resources/
            .deletingLastPathComponent()  // Contents/
        return fromContents(contents, isBeta: isBeta, fileManager: fileManager)
    }

    public static func fromAppBundle(bundleURL: URL, isBeta: Bool, fileManager: FileManager = .default) -> AgentGuidanceIdentity? {
        fromContents(bundleURL.appending(path: "Contents", directoryHint: .isDirectory), isBeta: isBeta, fileManager: fileManager)
    }

    private static func fromContents(_ contents: URL, isBeta: Bool, fileManager: FileManager) -> AgentGuidanceIdentity? {
        let infoPlist = contents.appending(path: "Info.plist", directoryHint: .notDirectory)
        let cli = contents.appending(path: "Resources/bin/batty", directoryHint: .notDirectory)
        let guidance = contents.appending(path: "Resources/AgentGuidance", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              fileManager.fileExists(atPath: guidance.appending(path: "skills/\(skillName)/SKILL.md").path(percentEncoded: false))
        else {
            return nil
        }
        return AgentGuidanceIdentity(isBeta: isBeta, cliExecutablePath: cli.path(percentEncoded: false), version: version, guidanceRoot: guidance)
    }
}
