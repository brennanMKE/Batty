// AgentGuidanceInstaller.swift

import Foundation

public nonisolated struct AgentCommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public nonisolated enum AgentHost: String, Sendable, Equatable, CaseIterable {
    case claudeCode = "Claude Code"
    case openCode = "OpenCode"
    case cursor = "Cursor"
    case codex = "Codex"
    case crossTool = "Cross-tool (~/.agents/skills)"
}

public nonisolated enum AgentInstallAction: Sendable, Equatable {
    /// Writes the local Claude Code marketplace (manifests, `.mcp.json`, skill).
    case stageMarketplace(directory: URL)
    case runClaude(executable: URL, arguments: [String])
    /// `claude` was not found: these commands are for the user to run.
    case printClaudeCommands([String])
    case copySkill(host: AgentHost, destination: URL)
    /// Sets `keyPath` in a strict-JSON config file, keeping everything else.
    case mergeMCPEntry(host: AgentHost, file: URL, keyPath: [String], entry: AgentJSON)
    case printMCPEntry(host: AgentHost, text: String)

    public var summary: String {
        switch self {
        case let .stageMarketplace(directory):
            "Stage the Claude Code plugin marketplace in \(directory.path(percentEncoded: false))"
        case let .runClaude(executable, arguments):
            "Run \(executable.path(percentEncoded: false)) \(arguments.joined(separator: " "))"
        case let .printClaudeCommands(commands):
            "claude not found; run these yourself:\n" + commands.map { "    \($0)" }.joined(separator: "\n")
        case let .copySkill(host, destination):
            "\(host.rawValue): copy the skill to \(destination.path(percentEncoded: false))"
        case let .mergeMCPEntry(host, file, keyPath, _):
            "\(host.rawValue): add MCP server \(keyPath.joined(separator: ".")) to \(file.path(percentEncoded: false))"
        case let .printMCPEntry(host, text):
            "\(host.rawValue): add this MCP server entry yourself:\n" + text.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
        }
    }
}

public nonisolated struct AgentInstallPlan: Sendable, Equatable {
    public let identity: AgentGuidanceIdentity
    public let hosts: [AgentHost]
    public let actions: [AgentInstallAction]

    public func render() -> String {
        var lines = ["\(identity.cliCommandName) \(identity.version) agent guidance — detected: \(hosts.map(\.rawValue).joined(separator: ", "))"]
        lines += actions.map { "  - \($0.summary)" }
        return lines.joined(separator: "\n")
    }
}

public nonisolated enum AgentInstallOutcome: Sendable, Equatable {
    case done(String)
    case unchanged
    /// Left for the user to do; the text says what.
    case manual(String)
    case failed(String)
}

public nonisolated struct AgentInstallReport: Sendable, Equatable {
    public let entries: [(action: AgentInstallAction, outcome: AgentInstallOutcome)]

    public var hasFailures: Bool {
        entries.contains { if case .failed = $0.outcome { true } else { false } }
    }

    public static func == (lhs: AgentInstallReport, rhs: AgentInstallReport) -> Bool {
        lhs.entries.map(\.action) == rhs.entries.map(\.action) && lhs.entries.map(\.outcome) == rhs.entries.map(\.outcome)
    }

    public func render() -> String {
        var lines: [String] = []
        for (action, outcome) in entries {
            switch outcome {
            case let .done(detail): lines.append("  ok: \(action.summary)\(detail.isEmpty ? "" : " — \(detail)")")
            case .unchanged: lines.append("  unchanged: \(action.summary)")
            case let .manual(detail): lines.append("  manual: \(action.summary)\(detail.isEmpty ? "" : "\n" + detail)")
            case let .failed(reason): lines.append("  FAILED: \(action.summary) — \(reason)")
            }
        }
        lines.append(hasFailures ? "Some destinations failed; the rest were installed." : "Done. Start a new agent session to pick up the changes. If the app moves, run this again.")
        return lines.joined(separator: "\n")
    }
}

/// A JSON value for MCP config entries, kept `Equatable` for plans.
public nonisolated indirect enum AgentJSON: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case array([AgentJSON])
    case object([(String, AgentJSON)])

    public static func == (lhs: AgentJSON, rhs: AgentJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        default: false
        }
    }

    var foundation: Any {
        switch self {
        case let .string(text): text
        case let .bool(flag): flag
        case let .array(items): items.map(\.foundation)
        case let .object(fields): Dictionary(fields.map { ($0.0, $0.1.foundation) }, uniquingKeysWith: { _, last in last })
        }
    }
}

/// Installs the bundled agent guidance for every detected agent host:
/// a Claude Code plugin (skill and MCP server) through Claude Code's own
/// plugin commands, and the skill plus MCP entry for Cursor, OpenCode and Codex.
public nonisolated struct AgentGuidanceInstaller: Sendable {
    public typealias CommandRunner = @Sendable (URL, [String]) -> AgentCommandResult
    public typealias ExecutableLookup = @Sendable (String) -> URL?

    public let homeDirectory: URL
    public let environment: [String: String]
    public let commandRunner: CommandRunner
    public let executableLookup: ExecutableLookup
    public let now: @Sendable () -> Date

    public init(
        homeDirectory: URL,
        environment: [String: String],
        commandRunner: @escaping CommandRunner,
        executableLookup: ExecutableLookup? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.commandRunner = commandRunner
        self.executableLookup = executableLookup ?? Self.pathLookup(homeDirectory: homeDirectory, environment: environment)
        self.now = now
    }

    /// A launchd-started app's `PATH` lacks `~/.local/bin`, so the usual
    /// install locations are searched after `PATH`.
    public static func pathLookup(homeDirectory: URL, environment: [String: String]) -> ExecutableLookup {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let fallbacks = [
            homeDirectory.appending(path: ".local/bin", directoryHint: .isDirectory),
            homeDirectory.appending(path: ".claude/local", directoryHint: .isDirectory),
            URL(filePath: "/opt/homebrew/bin", directoryHint: .isDirectory),
            URL(filePath: "/usr/local/bin", directoryHint: .isDirectory),
        ]
        let directories = pathDirectories + fallbacks
        return { name in
            directories
                .map { $0.appending(path: name, directoryHint: .notDirectory) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
        }
    }

    /// Runs a command with the caller's environment, capturing both streams.
    public static let processRunner: CommandRunner = { executable, arguments in
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outFile = FileManager.default.temporaryDirectory.appending(path: "batty-agent-\(UUID().uuidString).out")
        let errFile = FileManager.default.temporaryDirectory.appending(path: "batty-agent-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outFile.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: errFile.path(percentEncoded: false), contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        do {
            process.standardOutput = try FileHandle(forWritingTo: outFile)
            process.standardError = try FileHandle(forWritingTo: errFile)
            try process.run()
        } catch {
            return AgentCommandResult(status: 127, stdout: "", stderr: String(describing: error))
        }
        process.waitUntilExit()
        let out = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return AgentCommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    // MARK: - Paths

    public func appSupportDirectory(for identity: AgentGuidanceIdentity) -> URL {
        homeDirectory.appending(path: "Library/Application Support/\(identity.appSupportDirectoryName)", directoryHint: .isDirectory)
    }

    public func marketplaceDirectory(for identity: AgentGuidanceIdentity) -> URL {
        appSupportDirectory(for: identity).appending(path: "AgentPlugin", directoryHint: .isDirectory)
    }

    private var openCodeDirectory: URL {
        let config = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "opencode", directoryHint: .isDirectory)
    }

    private var codexDirectory: URL {
        environment["CODEX_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
    }

    private var claudeDirectory: URL {
        environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Plan

    public func plan(identity: AgentGuidanceIdentity) -> AgentInstallPlan {
        var hosts: [AgentHost] = []
        var actions: [AgentInstallAction] = []
        let key = identity.pluginName
        let skillDirectory = identity.hostSkillDirectoryName

        let claude = executableLookup("claude")
        if claude != nil || exists(claudeDirectory) {
            hosts.append(.claudeCode)
            let marketplace = marketplaceDirectory(for: identity)
            actions.append(.stageMarketplace(directory: marketplace))
            let add = ["plugin", "marketplace", "add", marketplace.path(percentEncoded: false)]
            let install = ["plugin", "install", "\(identity.pluginName)@\(identity.marketplaceName)"]
            if let claude {
                actions.append(.runClaude(executable: claude, arguments: add))
                actions.append(.runClaude(executable: claude, arguments: install))
            } else {
                actions.append(.printClaudeCommands([add, install].map { (["claude"] + $0.map(Self.shellQuoted)).joined(separator: " ") }))
            }
        }

        if executableLookup("opencode") != nil || exists(openCodeDirectory) {
            hosts.append(.openCode)
            actions.append(.copySkill(host: .openCode, destination: openCodeDirectory.appending(path: "skills/\(skillDirectory)", directoryHint: .isDirectory)))
            actions.append(.mergeMCPEntry(
                host: .openCode,
                file: openCodeDirectory.appending(path: "opencode.json", directoryHint: .notDirectory),
                keyPath: ["mcp", key],
                entry: .object([
                    ("type", .string("local")),
                    ("command", .array([.string(identity.cliExecutablePath), .string("mcp")])),
                    ("enabled", .bool(true)),
                ])
            ))
        }

        let cursorDirectory = homeDirectory.appending(path: ".cursor", directoryHint: .isDirectory)
        if executableLookup("cursor") != nil || exists(cursorDirectory) {
            hosts.append(.cursor)
            actions.append(.copySkill(host: .cursor, destination: cursorDirectory.appending(path: "skills/\(skillDirectory)", directoryHint: .isDirectory)))
            actions.append(.mergeMCPEntry(
                host: .cursor,
                file: cursorDirectory.appending(path: "mcp.json", directoryHint: .notDirectory),
                keyPath: ["mcpServers", key],
                entry: .object([
                    ("command", .string(identity.cliExecutablePath)),
                    ("args", .array([.string("mcp")])),
                ])
            ))
        }

        if executableLookup("codex") != nil || exists(codexDirectory) {
            hosts.append(.codex)
            actions.append(.copySkill(host: .codex, destination: codexDirectory.appending(path: "skills/\(skillDirectory)", directoryHint: .isDirectory)))
            // Foundation can't round-trip TOML, so Codex's config is never edited.
            actions.append(.printMCPEntry(host: .codex, text: """
                [mcp_servers.\(key)]
                command = "\(identity.cliExecutablePath)"
                args = ["mcp"]
                """))
        }

        hosts.append(.crossTool)
        actions.append(.copySkill(host: .crossTool, destination: homeDirectory.appending(path: ".agents/skills/\(skillDirectory)", directoryHint: .isDirectory)))

        return AgentInstallPlan(identity: identity, hosts: hosts, actions: actions)
    }

    private static func shellQuoted(_ text: String) -> String {
        text.contains(where: { " '\"$\\".contains($0) }) ? "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" : text
    }

    // MARK: - Apply

    /// Applies every action; one failed destination never stops the rest.
    public func apply(_ plan: AgentInstallPlan) -> AgentInstallReport {
        var entries: [(action: AgentInstallAction, outcome: AgentInstallOutcome)] = []
        let stamp = Self.timestamp(now())
        for action in plan.actions {
            let outcome: AgentInstallOutcome
            do {
                outcome = try perform(action, identity: plan.identity, stamp: stamp)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            entries.append((action, outcome))
        }
        return AgentInstallReport(entries: entries)
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func perform(_ action: AgentInstallAction, identity: AgentGuidanceIdentity, stamp: String) throws -> AgentInstallOutcome {
        switch action {
        case let .stageMarketplace(directory):
            try stageMarketplace(at: directory, identity: identity)
            return .done("")
        case let .runClaude(executable, arguments):
            let result = commandRunner(executable, arguments)
            guard result.status == 0 else {
                throw InstallError(message: "exit \(result.status): \(result.stderr.isEmpty ? result.stdout : result.stderr)".trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .done(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        case .printClaudeCommands, .printMCPEntry:
            return .manual("")
        case let .copySkill(host, destination):
            return try copySkill(identity: identity, host: host, destination: destination, stamp: stamp)
        case let .mergeMCPEntry(host, file, keyPath, entry):
            return try mergeMCPEntry(identity: identity, host: host, file: file, keyPath: keyPath, entry: entry, stamp: stamp)
        }
    }

    func skillText(identity: AgentGuidanceIdentity, renamed: Bool) throws -> Data {
        let source = identity.skillSourceDirectory.appending(path: "SKILL.md", directoryHint: .notDirectory)
        let data = try Data(contentsOf: source)
        guard renamed, identity.hostSkillDirectoryName != AgentGuidanceIdentity.skillName else { return data }
        let text = String(decoding: data, as: UTF8.self)
        let renamedText = text.replacingOccurrences(
            of: "\nname: \(AgentGuidanceIdentity.skillName)\n",
            with: "\nname: \(identity.hostSkillDirectoryName)\n"
        )
        return Data(renamedText.utf8)
    }

    private func stageMarketplace(at directory: URL, identity: AgentGuidanceIdentity) throws {
        let fileManager = FileManager.default
        let pluginDirectory = directory.appending(path: identity.pluginName, directoryHint: .isDirectory)
        if exists(pluginDirectory) { try fileManager.removeItem(at: pluginDirectory) }
        let description = "Drive the Batty terminal multiplexer: the \(AgentGuidanceIdentity.skillName) skill and the `\(identity.cliCommandName) mcp` server."
        try writeJSON([
            "name": identity.marketplaceName,
            "description": "Batty's agent guidance, staged from \(identity.cliCommandName) \(identity.version).",
            "owner": ["name": "Batty"],
            "plugins": [[
                "name": identity.pluginName,
                "source": "./\(identity.pluginName)",
                "description": description,
                "version": identity.version,
            ]],
        ], to: directory.appending(path: ".claude-plugin/marketplace.json"))
        try writeJSON([
            "name": identity.pluginName,
            "version": identity.version,
            "description": description,
            "author": ["name": "Batty"],
        ], to: pluginDirectory.appending(path: ".claude-plugin/plugin.json"))
        try writeJSON([
            "mcpServers": [identity.pluginName: ["command": identity.cliExecutablePath, "args": ["mcp"]]],
        ], to: pluginDirectory.appending(path: ".mcp.json"))
        let skill = pluginDirectory.appending(path: "skills/\(AgentGuidanceIdentity.skillName)/SKILL.md")
        try fileManager.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skillText(identity: identity, renamed: false).write(to: skill, options: .atomic)
    }

    private func writeJSON(_ object: Any, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }

    /// Staged outside the skills root, checked, then swapped in. A different
    /// existing copy is moved to a backup folder outside every scanned skills root.
    private func copySkill(identity: AgentGuidanceIdentity, host: AgentHost, destination: URL, stamp: String) throws -> AgentInstallOutcome {
        let fileManager = FileManager.default
        let content = try skillText(identity: identity, renamed: true)
        let existingSkill = destination.appending(path: "SKILL.md", directoryHint: .notDirectory)
        if let existing = try? Data(contentsOf: existingSkill), existing == content {
            return .unchanged
        }
        let support = appSupportDirectory(for: identity)
        let staging = support.appending(path: "AgentGuidanceStaging/\(UUID().uuidString)/\(destination.lastPathComponent)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging.deletingLastPathComponent()) }
        let stagedSkill = staging.appending(path: "SKILL.md", directoryHint: .notDirectory)
        try content.write(to: stagedSkill, options: .atomic)
        guard (try? Data(contentsOf: stagedSkill)) == content else {
            throw InstallError(message: "staged SKILL.md did not verify; existing copy left untouched")
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var detail = ""
        if (try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))) != nil {
            let backup = support.appending(path: "AgentGuidanceBackups/\(stamp)/\(Self.slug(host))/\(destination.lastPathComponent)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: destination, to: backup)
            detail = "previous copy backed up to \(backup.path(percentEncoded: false))"
        }
        try fileManager.moveItem(at: staging, to: destination)
        return .done(detail)
    }

    /// Numbers stay `Decimal` so a value like `0.2` is written back as
    /// written, not as its nearest `Double`.
    private indirect enum ConfigJSON: Codable, Equatable {
        case null
        case bool(Bool)
        case number(Decimal)
        case string(String)
        case array([ConfigJSON])
        case object([String: ConfigJSON])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Decimal.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([ConfigJSON].self) { self = .array(value) }
            else { self = .object(try container.decode([String: ConfigJSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case let .bool(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .object(value): try container.encode(value)
            }
        }

        init(_ entry: AgentJSON) {
            switch entry {
            case let .string(text): self = .string(text)
            case let .bool(flag): self = .bool(flag)
            case let .array(items): self = .array(items.map(ConfigJSON.init))
            case let .object(fields): self = .object(Dictionary(fields.map { ($0.0, ConfigJSON($0.1)) }, uniquingKeysWith: { _, last in last }))
            }
        }
    }

    /// Only Batty's own key is replaced. The previous file is backed up first.
    private func mergeMCPEntry(identity: AgentGuidanceIdentity, host: AgentHost, file: URL, keyPath: [String], entry: AgentJSON, stamp: String) throws -> AgentInstallOutcome {
        guard keyPath.count == 2 else { throw InstallError(message: "bad key path") }
        var root: [String: ConfigJSON] = [:]
        let original = try? Data(contentsOf: file)
        if let original {
            guard case let .object(fields)? = try? JSONDecoder().decode(ConfigJSON.self, from: original) else {
                return .manual("    \(file.lastPathComponent) is not strict JSON (comments?), so it was left untouched. Add this entry yourself:\n\(Self.entryText(keyPath: keyPath, entry: entry))")
            }
            root = fields
        }
        var section: [String: ConfigJSON] = [:]
        if let existing = root[keyPath[0]] {
            guard case let .object(fields) = existing else {
                throw InstallError(message: "\"\(keyPath[0])\" in \(file.lastPathComponent) is not an object; left untouched")
            }
            section = fields
        }
        let value = ConfigJSON(entry)
        if section[keyPath[1]] == value { return .unchanged }
        section[keyPath[1]] = value
        root[keyPath[0]] = .object(section)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(ConfigJSON.object(root))
        data.append(0x0A)
        var detail = ""
        if let original {
            let backup = appSupportDirectory(for: identity).appending(path: "AgentGuidanceBackups/\(stamp)/\(Self.slug(host))/\(file.lastPathComponent)", directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: backup, options: .atomic)
            detail = "previous file backed up to \(backup.path(percentEncoded: false))"
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return .done(detail)
    }

    static func entryText(keyPath: [String], entry: AgentJSON) -> String {
        let object: [String: Any] = [keyPath[0]: [keyPath[1]: entry.foundation]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func slug(_ host: AgentHost) -> String {
        switch host {
        case .claudeCode: "claude-code"
        case .openCode: "opencode"
        case .cursor: "cursor"
        case .codex: "codex"
        case .crossTool: "agents"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
