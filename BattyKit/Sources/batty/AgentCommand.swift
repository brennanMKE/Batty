// AgentCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty agent`: agent-integration verbs.
struct AgentNounCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Set up AI coding agents to use Batty.",
        subcommands: [AgentInstallCommand.self]
    )
}

/// `batty agent install`: installs the bundled skill and MCP server for every
/// detected agent host, and optionally the Batty section of a project's agent file.
struct AgentInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Batty skill and MCP server for Claude Code, Codex, Cursor and OpenCode."
    )

    @Flag(name: .long, help: "Print what would be installed and write nothing.")
    var dryRun = false

    @Option(name: .long, help: "Also add a Batty section to this project's AGENTS.md or CLAUDE.md.")
    var project: String?

    @Flag(name: .long, help: "Write the project section without asking (required when not interactive).")
    var yes = false

    nonisolated func run() throws {
        guard let executable = Bundle.main.executableURL,
              let identity = AgentGuidanceIdentity.fromBundledCLI(executableURL: executable, isBeta: ServiceNames.current == .beta)
        else {
            fputs("batty: agent install must be run from the batty inside Batty.app\n", stderr)
            throw ExitCode.failure
        }
        let installer = AgentGuidanceInstaller(
            // `$HOME` first, as the shell installer does; `homeDirectoryForCurrentUser` ignores it.
            homeDirectory: ProcessInfo.processInfo.environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            commandRunner: AgentGuidanceInstaller.processRunner
        )
        let plan = installer.plan(identity: identity)
        var failed = false
        if dryRun {
            print("(dry run — nothing will be written)")
            print(plan.render())
        } else {
            print(plan.render().components(separatedBy: "\n").first ?? "")
            let report = installer.apply(plan)
            print(report.render())
            failed = report.hasFailures
        }
        if let project {
            failed = !Self.addSnippet(projectPath: project, dryRun: dryRun, yes: yes) || failed
        }
        if failed { throw ExitCode.failure }
    }

    private nonisolated static func addSnippet(projectPath: String, dryRun: Bool, yes: Bool) -> Bool {
        let directory = URL(filePath: projectPath, directoryHint: .isDirectory, relativeTo: URL.currentDirectory()).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            fputs("batty: --project \(projectPath) is not a directory\n", stderr)
            return false
        }
        let file = ProjectAgentSnippet.targetFile(in: directory)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        let updated: String
        do {
            updated = try ProjectAgentSnippet.apply(to: existing)
        } catch {
            fputs("batty: \(file.path(percentEncoded: false)): \(error.description)\n", stderr)
            return false
        }
        if updated == existing {
            print("Project: \(file.path(percentEncoded: false)) already has the current Batty section.")
            return true
        }
        print("Project: \(existing == nil ? "create" : "update") \(file.path(percentEncoded: false)) with:")
        print(ProjectAgentSnippet.block)
        switch ProjectAgentSnippet.confirmationRequired(isTTY: isatty(STDIN_FILENO) != 0, yes: yes, dryRun: dryRun) {
        case .preview:
            return true
        case .refuse:
            fputs("batty: not writing \(file.lastPathComponent) without confirmation; pass --yes when not interactive\n", stderr)
            return false
        case .prompt:
            print("Write it? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("Left unchanged.")
                return true
            }
        case .write:
            break
        }
        do {
            try Data(updated.utf8).write(to: file, options: .atomic)
            print("Wrote \(file.path(percentEncoded: false)).")
            return true
        } catch {
            fputs("batty: could not write \(file.path(percentEncoded: false)): \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

extension AgentInstallCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(properties: [
            "dry-run": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--dry-run"], type: "boolean", description: "Print what would be installed and write nothing.", required: false, defaultValue: "false"),
            "project": CapabilitiesPropertyPayload(cliKind: .option, names: ["--project"], type: "string", description: "Also add a Batty section to this project's AGENTS.md or CLAUDE.md.", required: false),
            "yes": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--yes"], type: "boolean", description: "Write the project section without asking (required when not interactive).", required: false, defaultValue: "false"),
        ])
    }
}
