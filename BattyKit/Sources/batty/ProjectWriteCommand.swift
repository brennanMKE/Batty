// ProjectWriteCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// The layout document, for `--help` and the capabilities descriptions.
nonisolated let projectLayoutSchemaText = """
A layout document is JSON: {"preset": NAME, "panes": [PANE...], "focusedPane": N} \
fills a preset's slots in order (omit "panes" for all terminals), or \
{"root": NODE} gives a tree, where NODE is a PANE or {"split": "horizontal"|"vertical", \
"children": [NODE, NODE...]}. A PANE is {"kind": "terminal"|"git-status"|"process-status"|"system-metrics"|"lm-studio-dashboard", \
"tabs": [TAB...] (terminal only), "repository": DIR (git-status only), \
"background": BG, "hidden": BOOL, "activeTab": N}. A TAB is {"title", "cwd" (relative to the \
Project root), "command", "background": BG}. A BG is one of {"id": URL from `batty background list`}, \
{"set": SET, "image": TITLE}, {"digest": D (My Images)} or {"file": PATH (relative to the current folder)}, \
plus "opacity" and "terminalOpacity" in percent (0-100). Unknown keys are errors.
"""

/// The options `project create` and `project edit` share.
struct ProjectWriteOptions: ParsableArguments {
    @Option(name: .long, help: "The Project's name. Names are unique, ignoring case.")
    var name: String?

    @Option(name: .long, help: "The Project's root folder: an existing directory. A relative path is resolved against the current folder.")
    var path: String?

    @Option(name: .long, help: "A palette color.")
    var color: String?

    @Option(name: .long, help: "A custom color as #RRGGBB.")
    var colorHex: String?

    @Option(name: .long, help: "A curated Project symbol.")
    var symbol: String?

    @Option(name: .long, help: "Any SF Symbol name.")
    var symbolName: String?

    @Option(name: .long, help: "A Theme for both Dark and Light appearance.")
    var theme: String?

    @Option(name: .long, help: "The Theme for Dark appearance.")
    var themeDark: String?

    @Option(name: .long, help: "The Theme for Light appearance.")
    var themeLight: String?

    @Flag(name: .long, help: "Follow the Settings Theme (clears the Project's Theme).")
    var noTheme = false

    @Option(name: .long, help: "A layout preset, every Pane a terminal.")
    var preset: String?

    @Option(name: .long, help: "A layout document file, or - for standard input.")
    var layout: String?

    @Option(name: .long, help: "A layout document as inline JSON. \(projectLayoutSchemaText)")
    var layoutJson: String?

    @Flag(name: .long, help: "Take the layout from a live Session, as Save Session as Project does.")
    var fromSession = false

    @Option(name: .long, help: "The Session for --from-session. Falls back to BATTY_SESSION_ID, then the focused Session.")
    var session: String?

    @Option(name: .long, help: "The Background Sets set of the Project's image (with --background-image).")
    var backgroundSet: String?

    @Option(name: .long, help: "The image's title in --background-set.")
    var backgroundImage: String?

    @Option(name: .long, help: "A Background Sets image by its id (full URL) from `batty background list`.")
    var backgroundId: String?

    @Option(name: .long, help: "A My Images image by its digest from `batty background list`.")
    var backgroundDigest: String?

    @Option(name: .long, help: "A local image file, copied into the Project's background folder.")
    var backgroundFile: String?

    @Flag(name: .long, help: "Remove the Project's background.")
    var noBackground = false

    @Option(name: .long, help: "The Project image's opacity in percent (0-100). A first image gets 15.")
    var opacity: Int?

    @Option(name: .long, help: "The terminal's opacity over the background in percent (0-100). Default 100.")
    var terminalOpacity: Int?

    @Option(name: .long, help: "A startup command for the next terminal Tab in slot order. Repeatable. Commands still need the user's approval at the first open.")
    var startupCommand: [String] = []

    @Flag(name: .long, help: "Emit JSON (id, name, rootPath, paneCount, tabCount, created, warnings, appliesOnNextOpen) instead of a sentence.")
    var json = false

    var imageSourceCount: Int {
        [backgroundSet != nil || backgroundImage != nil, backgroundId != nil, backgroundDigest != nil, backgroundFile != nil, noBackground].filter { $0 }.count
    }

    var layoutSourceCount: Int {
        [preset != nil, layout != nil, layoutJson != nil, fromSession].filter { $0 }.count
    }

    /// Whether any field is given, for `edit`.
    var changesSomething: Bool {
        name != nil || path != nil || color != nil || colorHex != nil || symbol != nil || symbolName != nil
            || theme != nil || themeDark != nil || themeLight != nil || noTheme || layoutSourceCount > 0
            || imageSourceCount > 0 || opacity != nil || terminalOpacity != nil || !startupCommand.isEmpty
    }

    nonisolated func validateCommon() throws {
        if color != nil, colorHex != nil { throw ValidationError("--color and --color-hex can't be used together") }
        if symbol != nil, symbolName != nil { throw ValidationError("--symbol and --symbol-name can't be used together") }
        if [theme != nil, themeDark != nil || themeLight != nil, noTheme].filter({ $0 }).count > 1 {
            throw ValidationError("use one of --theme, --theme-dark/--theme-light and --no-theme")
        }
        if layoutSourceCount > 1 { throw ValidationError("use one of --preset, --layout, --layout-json and --from-session") }
        if imageSourceCount > 1 {
            throw ValidationError("use one of --background-set/--background-image, --background-id, --background-digest, --background-file and --no-background")
        }
        if noBackground, opacity != nil || terminalOpacity != nil {
            throw ValidationError("--no-background can't be used with --opacity or --terminal-opacity")
        }
        if (backgroundSet == nil) != (backgroundImage == nil) {
            throw ValidationError("--background-set and --background-image go together")
        }
        if session != nil, !fromSession { throw ValidationError("--session needs --from-session") }
        if let session, UUID(uuidString: session) == nil { throw ValidationError("--session must be a Session id") }
        for (flag, value) in [("--opacity", opacity), ("--terminal-opacity", terminalOpacity)] {
            if let value, !(0...100).contains(value) { throw ValidationError("\(flag) must be from 0 to 100") }
        }
        if let preset, !ProjectVocabulary.presetNames.contains(preset) {
            throw ValidationError("--preset must be one of \(ProjectVocabulary.presetNames.joined(separator: ", "))")
        }
        if let color, !ProjectVocabulary.colorNames.contains(color) {
            throw ValidationError("--color must be one of \(ProjectVocabulary.colorNames.joined(separator: ", "))")
        }
        if let symbol, !ProjectVocabulary.symbolNames.contains(symbol) {
            throw ValidationError("--symbol must be one of \(ProjectVocabulary.symbolNames.joined(separator: ", ")), or use --symbol-name")
        }
    }

    nonisolated static func resolvedPath(_ path: String, cwd: String) -> String {
        ProjectLayoutDocument.absolute(path, cwd: cwd)
    }

    /// The bytes of `--layout`: `-` reads `standardInput` to its end, any
    /// other value is a file resolved against `cwd`.
    nonisolated static func layoutData(from argument: String, cwd: String, standardInput: FileHandle) throws(ProjectWriteCLIError) -> Data {
        if argument == "-" { return standardInput.readDataToEndOfFile() }
        let file = resolvedPath(argument, cwd: cwd)
        guard let data = FileManager.default.contents(atPath: file) else {
            throw ProjectWriteCLIError("can't read the layout file \(file)")
        }
        return data
    }

    nonisolated func request(target: String?, cwd: String, environment: [String: String], standardInput: FileHandle) throws(ProjectWriteCLIError) -> ProjectWriteRequest {
        var layoutSource: ProjectWriteRequest.LayoutSource?
        if let preset { layoutSource = .preset(preset) }
        let documentData: Data? = if let layout {
            try Self.layoutData(from: layout, cwd: cwd, standardInput: standardInput)
        } else {
            layoutJson.map { Data($0.utf8) }
        }
        if let documentData {
            do {
                layoutSource = .document(try ProjectLayoutDocument.parse(documentData).resolvingFiles(against: cwd))
            } catch {
                throw ProjectWriteCLIError(error.message)
            }
        }
        let sessionID = session.flatMap(UUID.init(uuidString:)) ?? environment["BATTY_SESSION_ID"].flatMap(UUID.init(uuidString:))
        if fromSession { layoutSource = .fromSession(session.flatMap(UUID.init(uuidString:))) }
        var background: ProjectWriteRequest.BackgroundChoice?
        if let backgroundSet, let backgroundImage { background = .hosted(set: backgroundSet, title: backgroundImage) }
        if let backgroundId { background = .hostedID(backgroundId) }
        if let backgroundDigest { background = .myImage(digest: backgroundDigest) }
        if let backgroundFile { background = .file(Self.resolvedPath(backgroundFile, cwd: cwd)) }
        if noBackground { background = ProjectWriteRequest.BackgroundChoice.none }
        return ProjectWriteRequest(
            target: target, name: name, rootPath: path.map { Self.resolvedPath($0, cwd: cwd) },
            color: color, colorHex: colorHex, symbol: symbol, symbolName: symbolName,
            themeDark: theme ?? themeDark, themeLight: theme ?? themeLight, clearTheme: noTheme,
            layout: layoutSource, background: background,
            imageOpacityPercent: opacity, terminalOpacityPercent: terminalOpacity,
            startupCommands: startupCommand.isEmpty ? nil : startupCommand,
            callerSessionID: sessionID)
    }

    nonisolated func run(verb: String, target: String?) throws {
        let request: ProjectWriteRequest
        do {
            request = try self.request(
                target: target, cwd: FileManager.default.currentDirectoryPath,
                environment: ProcessInfo.processInfo.environment, standardInput: .standardInput)
        } catch {
            fputs("batty: \(error.message)\n", stderr)
            throw ExitCode(XPCExitCode.requestFailed)
        }
        let endpoint = try resolveProjectAppEndpoint()
        switch AppServiceClient.projectWrite(verb: verb, request: request, endpoint: endpoint, timeout: TimeInterval(ProjectWriteRequest.timeoutSeconds + 10)) {
        case .success(let reply):
            for warning in reply.warnings { fputs("batty: warning: \(warning)\n", stderr) }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(reply), let text = String(data: data, encoding: .utf8) else {
                    fputs("batty: failed to encode the Project as JSON\n", stderr)
                    throw ExitCode.failure
                }
                print(text)
            } else {
                print(Self.sentence(for: reply))
            }
        case .unreachable:
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .requestFailed(let message):
            fputs("batty: request failed — \(message)\n", stderr)
            throw ExitCode(XPCExitCode.requestFailed)
        case .appTerminated:
            fputs("batty: app terminated\n", stderr)
            throw ExitCode(XPCExitCode.sessionTerminated)
        }
    }

    nonisolated static func sentence(for reply: ProjectWriteReply) -> String {
        var text = "\(reply.created ? "Created" : "Updated") Project \"\(reply.name)\""
        if !reply.appliesOnNextOpen.isEmpty {
            text += " (\(reply.appliesOnNextOpen.joined(separator: ", ")) applies the next time the Project opens)"
        }
        return text
    }

    nonisolated static func properties(edit: Bool) -> [String: CapabilitiesPropertyPayload] {
        func option(_ key: String, _ description: String, type: String = "string", enumValues: [String]? = nil, minimum: Int? = nil, maximum: Int? = nil) -> CapabilitiesPropertyPayload {
            CapabilitiesPropertyPayload(cliKind: .option, names: ["--\(key)"], type: type, description: description, required: false, enumValues: enumValues, minimum: minimum, maximum: maximum)
        }
        func flag(_ key: String, _ description: String) -> CapabilitiesPropertyPayload {
            CapabilitiesPropertyPayload(cliKind: .flag, names: ["--\(key)"], type: "boolean", description: description, required: false, defaultValue: "false")
        }
        return [
            "name": option("name", edit ? "Rename the Project. Names are unique, ignoring case." : "The Project's name (required unless from-session). Names are unique, ignoring case."),
            "path": option("path", "The Project's root folder: an absolute path to an existing directory (a relative one is resolved against the CLI's current folder). Required on create unless from-session."),
            "color": option("color", "A palette color.", enumValues: ProjectVocabulary.colorNames),
            "color-hex": option("color-hex", "A custom color as #RRGGBB."),
            "symbol": option("symbol", "A curated Project symbol.", enumValues: ProjectVocabulary.symbolNames),
            "symbol-name": option("symbol-name", "Any SF Symbol name."),
            "theme": option("theme", "A Theme for both Dark and Light appearance."),
            "theme-dark": option("theme-dark", "The Theme for Dark appearance."),
            "theme-light": option("theme-light", "The Theme for Light appearance."),
            "no-theme": flag("no-theme", "Follow the Settings Theme (clears the Project's Theme)."),
            "preset": option("preset", "A layout preset, every Pane a terminal\(edit ? "; replaces the layout, which open Sessions pick up at the next open" : "").", enumValues: ProjectVocabulary.presetNames),
            "layout": option("layout", "A layout document file path, or - for standard input (not available over MCP; use layout-json)."),
            "layout-json": option("layout-json", "A layout document as inline JSON. \(projectLayoutSchemaText)"),
            "from-session": flag("from-session", "Take the layout from a live Session, as Save Session as Project does."),
            "session": option("session", "The Session id for from-session. Falls back to BATTY_SESSION_ID, then the focused Session."),
            "background-set": option("background-set", "The Background Sets set of the Project's image (with background-image)."),
            "background-image": option("background-image", "The image's title in background-set."),
            "background-id": option("background-id", "A Background Sets image by its id (full URL) from background list."),
            "background-digest": option("background-digest", "A My Images image by its digest from background list."),
            "background-file": option("background-file", "A local image file, copied into the Project's background folder."),
            "no-background": flag("no-background", "Remove the Project's background."),
            "opacity": option("opacity", "The Project image's opacity in percent. A first image gets 15; needs an image.", type: "integer", minimum: 0, maximum: 100),
            "terminal-opacity": option("terminal-opacity", "The terminal's opacity over the background in percent. Default 100.", type: "integer", minimum: 0, maximum: 100),
            "startup-command": CapabilitiesPropertyPayload(cliKind: .option, names: ["--startup-command"], type: "array", description: "Startup commands, one per terminal Tab in slot order. They still need the user's approval at the first open.", required: false),
            "json": flag("json", "Emit JSON (id, name, rootPath, paneCount, tabCount, created, warnings, appliesOnNextOpen) instead of a sentence."),
        ]
    }

    nonisolated static let conflicts: [CapabilitiesConstraintPayload] = [
        .mutuallyExclusive(["color", "color-hex"], description: "--color and --color-hex can't be used together"),
        .mutuallyExclusive(["symbol", "symbol-name"], description: "--symbol and --symbol-name can't be used together"),
        .mutuallyExclusive(["theme", "theme-dark", "no-theme"], description: "use one of --theme, --theme-dark/--theme-light and --no-theme"),
        .mutuallyExclusive(["theme", "theme-light", "no-theme"], description: "use one of --theme, --theme-dark/--theme-light and --no-theme"),
        .mutuallyExclusive(["preset", "layout", "layout-json", "from-session"], description: "use one of --preset, --layout, --layout-json and --from-session"),
        .mutuallyExclusive(["background-set", "background-id", "background-digest", "background-file", "no-background"], description: "use one of --background-set/--background-image, --background-id, --background-digest, --background-file and --no-background"),
        .mutuallyExclusive(["no-background", "opacity"], description: "--no-background can't be used with --opacity or --terminal-opacity"),
        .mutuallyExclusive(["no-background", "terminal-opacity"], description: "--no-background can't be used with --opacity or --terminal-opacity"),
        .requires(parameter: "background-set", requiresParameter: "background-image", allowedValues: nil, allowsOmission: false, description: "--background-set and --background-image go together"),
        .requires(parameter: "background-image", requiresParameter: "background-set", allowedValues: nil, allowsOmission: false, description: "--background-set and --background-image go together"),
        .requires(parameter: "session", requiresParameter: "from-session", allowedValues: nil, allowsOmission: false, description: "--session needs --from-session"),
    ]
}

struct ProjectWriteCLIError: Error, Equatable {
    let message: String

    init(_ message: String) { self.message = message }
}

/// `batty project create` — saves a new Project. Never overwrites a Project
/// and never approves startup commands.
struct ProjectCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Save a new Project: its root, look, layout and background.",
        discussion: """
        Needs --name and --path unless --from-session. Defaults: color blue, \
        symbol folder, the Settings Theme, one terminal Pane, no background. \
        A name already in use (ignoring case) exits 4 and nothing is saved. \
        Errors name the field and exit 4; warnings (a Tab folder that doesn't \
        exist yet, an unknown Theme) go to stderr and don't stop the save. \
        Startup commands are never approved here: the first `batty project \
        open` asks the user.

        \(projectLayoutSchemaText)
        """,
        helpNames: .long
    )

    @OptionGroup var options: ProjectWriteOptions

    nonisolated func validate() throws {
        try options.validateCommon()
        if !options.fromSession, options.name == nil || options.path == nil {
            throw ValidationError("--name and --path are required unless --from-session")
        }
    }

    nonisolated func run() throws {
        try options.run(verb: XPCVerb.projectCreate, target: nil)
    }
}

/// `batty project edit <name|id>` — changes only the fields given, then
/// applies name, color, symbol, Theme and background to open Sessions.
struct ProjectEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Change the given fields of a saved Project.",
        discussion: """
        Fields not given keep their stored values, including Pane and Tab \
        backgrounds. --preset, --layout, --layout-json and --from-session \
        replace the whole layout; open Sessions pick up a layout change the \
        next time the Project opens, and the other changes at once. \
        --opacity alone changes the opacity of the existing image. An \
        unknown name exits 4 and lists the close matches.

        \(projectLayoutSchemaText)
        """,
        helpNames: .long
    )

    @Argument(help: "The saved Project's name (case-insensitive) or id.")
    var target: String

    @OptionGroup var options: ProjectWriteOptions

    nonisolated func validate() throws {
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("the Project name must not be empty")
        }
        try options.validateCommon()
        if !options.changesSomething { throw ValidationError("give at least one field to change") }
    }

    nonisolated func run() throws {
        try options.run(verb: XPCVerb.projectEdit, target: target)
    }
}

extension ProjectCreateCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: ProjectWriteOptions.properties(edit: false), conflicts: ProjectWriteOptions.conflicts)
    }
}

extension ProjectEditCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        var properties = ProjectWriteOptions.properties(edit: true)
        properties["target"] = CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "The saved Project's name (case-insensitive) or id.", required: true)
        return CapabilitiesInputSchemaPayload(properties: properties, required: ["target"], conflicts: ProjectWriteOptions.conflicts)
    }
}
