// AgentIntegrationModelTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct AgentIntegrationModelTests {
    private func model(_ fixture: AgentInstallFixture, runner: RecordingCommandRunner) throws -> AgentIntegrationModel {
        let identity = try fixture.identity()
        let installer = fixture.installer(runner: runner, executables: ["claude": URL(filePath: "/fake/claude")])
        return AgentIntegrationModel(identity: { identity }, installer: { installer })
    }

    @Test func installButtonPreviewsBeforeApplying() async throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingCommandRunner()
        let model = try model(fixture, runner: runner)
        await model.beginInstall()
        guard case .previewing = model.state else {
            Issue.record("expected a preview, got \(model.state)")
            return
        }
        #expect(model.isConfirming)
        #expect(runner.calls.isEmpty)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") == nil)
        await model.confirmInstall()
        guard case let .finished(report) = model.state else {
            Issue.record("expected a report, got \(model.state)")
            return
        }
        #expect(!report.hasFailures)
        #expect(runner.calls.count == 2)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") != nil)
    }

    @Test func cancelFromPreviewAppliesNothing() async throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let runner = RecordingCommandRunner()
        let model = try model(fixture, runner: runner)
        await model.beginInstall()
        model.cancel()
        #expect(model.state == .idle)
        await model.confirmInstall()
        #expect(model.state == .idle)
        #expect(runner.calls.isEmpty)
        #expect(fixture.read(".agents/skills/batty-cli/SKILL.md") == nil)
    }

    @Test func snippetIsWrittenOnlyAfterConfirmation() async throws {
        let fixture = try AgentInstallFixture()
        defer { fixture.cleanUp() }
        let project = fixture.root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("# Project\n".utf8).write(to: project.appending(path: "CLAUDE.md"))
        let model = try model(fixture, runner: RecordingCommandRunner())
        await model.beginSnippet(directory: project)
        guard case let .snippetPreview(file, newText) = model.state else {
            Issue.record("expected a snippet preview, got \(model.state)")
            return
        }
        #expect(file.lastPathComponent == "CLAUDE.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Project\n")
        await model.confirmSnippet()
        #expect(model.state == .snippetWritten(file))
        #expect(try String(contentsOf: file, encoding: .utf8) == newText)
        #expect(newText.contains(ProjectAgentSnippet.beginMarker))
    }
}
