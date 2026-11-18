// MCPCommand.swift

import ArgumentParser
import BattyXPCCore
import Foundation

/// `batty mcp`: serves every verb `batty capabilities` lists as an MCP tool
/// over stdin/stdout, until stdin closes.
struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve this CLI's verbs as MCP tools over stdin/stdout."
    )

    nonisolated func run() throws {
        guard let executableURL = Bundle.main.executableURL else {
            fputs("batty: cannot locate this executable to run tools\n", stderr)
            throw ExitCode.failure
        }
        let payload = CapabilitiesCommand.buildPayload()
        let server = MCPServer(
            catalog: MCPToolCatalog(payload: payload),
            runner: SubprocessToolRunner(executableURL: executableURL),
            serverName: ServiceNames.current.cliCommandName,
            serverVersion: payload.cliVersion
        )
        // The root command is a blocking ParsableCommand, so bridge here.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await server.serve(input: .standardInput, output: .standardOutput)
            done.signal()
        }
        done.wait()
    }
}

extension MCPCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload { .empty }
}
