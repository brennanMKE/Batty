// BackgroundCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty background` — the images a Project can use. Read-only; the app
/// owns the Background Sets catalogs and My Images and answers over XPC.
struct BackgroundNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "background",
        abstract: "List the images Batty can use as backgrounds.",
        subcommands: [BackgroundListCommand.self]
    )
}

struct BackgroundListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Background Sets images and My Images.",
        discussion: """
        Lists every image in the Background Sets catalogs Batty has loaded, \
        with its set, title and id (the full-size URL, which is stable), and \
        My Images by digest. Pass an id to `batty project create \
        --background-id`, or a digest to --background-digest. Batty never \
        fetches the built-in catalog before Background Sets has been opened \
        once; until then only a saved copy is listed. Catalog problems are \
        warnings on stderr; nothing to list exits 4. Read-only.
        """,
        helpNames: .long
    )

    @Option(name: .long, help: "Only this set (case-insensitive, exact). \"My Images\" lists My Images.")
    var set: String?

    @Flag(name: .long, help: "Emit JSON (images with set, title, id, source, thumbnailURL, fullURL, catalogURL, downloaded, digest; warnings).")
    var json = false

    nonisolated func run() throws {
        let endpoint = try resolveProjectAppEndpoint()
        switch AppServiceClient.backgroundList(endpoint: endpoint, request: BackgroundListRequest(set: set), timeout: TimeInterval(BackgroundListRequest.timeoutSeconds + 5)) {
        case .success(let reply):
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(reply), let text = String(data: data, encoding: .utf8) else {
                    fputs("batty: failed to encode the background list as JSON\n", stderr)
                    throw ExitCode.failure
                }
                print(text)
            } else {
                for warning in reply.warnings { fputs("batty: warning: \(warning)\n", stderr) }
                print(Self.table(reply.images))
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

    nonisolated static func table(_ images: [BackgroundListEntry]) -> String {
        guard !images.isEmpty else { return "No background images." }
        let rows = images.map { ($0.set, $0.title, $0.id, $0.downloaded ? "yes" : "no") }
        let setWidth = max("SET".count, rows.map(\.0.count).max() ?? 0) + 2
        let titleWidth = max("TITLE".count, rows.map(\.1.count).max() ?? 0) + 2
        let idWidth = max("ID".count, rows.map(\.2.count).max() ?? 0) + 2
        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }
        var lines = [pad("SET", setWidth) + pad("TITLE", titleWidth) + pad("ID", idWidth) + "DOWNLOADED"]
        for (set, title, id, downloaded) in rows {
            lines.append(pad(set, setWidth) + pad(title, titleWidth) + pad(id, idWidth) + downloaded)
        }
        return lines.joined(separator: "\n")
    }
}

extension BackgroundListCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "set": CapabilitiesPropertyPayload(cliKind: .option, names: ["--set"], type: "string", description: "Only this set (case-insensitive, exact). \"My Images\" lists My Images.", required: false),
            "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON (images with set, title, id, source, thumbnailURL, fullURL, catalogURL, downloaded, digest; warnings).", required: false, defaultValue: "false"),
        ])
    }
}
