// AgentIntegrationModel.swift

import Foundation
import Observation

/// Drives Settings → Advanced → AI Agents. Nothing is written until the user
/// confirms a preview; every state change starts from a button.
@Observable
public final class AgentIntegrationModel {
    public enum State: Equatable {
        case idle
        case previewing(AgentInstallPlan)
        case installing
        case finished(AgentInstallReport)
        case snippetPreview(file: URL, newText: String)
        case snippetWritten(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle

    @ObservationIgnored private let identity: @Sendable () -> AgentGuidanceIdentity?
    @ObservationIgnored private let installer: @Sendable () -> AgentGuidanceInstaller

    public init(
        identity: @escaping @Sendable () -> AgentGuidanceIdentity?,
        installer: @escaping @Sendable () -> AgentGuidanceInstaller
    ) {
        self.identity = identity
        self.installer = installer
    }

    /// Reads nothing until a button is pressed.
    public convenience init() {
        self.init(identity: Self.liveIdentity, installer: Self.liveInstaller)
    }

    @Sendable nonisolated static func liveIdentity() -> AgentGuidanceIdentity? {
        let isBeta = ServiceNames.Variant(bundleIdentifier: Bundle.main.bundleIdentifier) == .beta
        return AgentGuidanceIdentity.fromAppBundle(bundleURL: Bundle.main.bundleURL, isBeta: isBeta)
    }

    @Sendable nonisolated static func liveInstaller() -> AgentGuidanceInstaller {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? FileManager.default.homeDirectoryForCurrentUser
        return AgentGuidanceInstaller(homeDirectory: home, environment: environment, commandRunner: AgentGuidanceInstaller.processRunner)
    }

    public var isBusy: Bool { state == .installing }

    public var isConfirming: Bool {
        switch state {
        case .previewing, .snippetPreview: true
        default: false
        }
    }

    public func beginInstall() async {
        let identity = identity
        let installer = installer
        let plan = await Task.detached { () -> AgentInstallPlan? in
            guard let identity = identity() else { return nil }
            return installer().plan(identity: identity)
        }.value
        guard let plan else {
            state = .failed(String(localized: "This build has no bundled agent guidance."))
            return
        }
        state = .previewing(plan)
    }

    public func confirmInstall() async {
        guard case let .previewing(plan) = state else { return }
        state = .installing
        let installer = installer
        let report = await Task.detached { installer().apply(plan) }.value
        state = .finished(report)
    }

    public func beginSnippet(directory: URL) async {
        let result = await Task.detached { () -> Result<(URL, String), ProjectAgentSnippet.SnippetError> in
            let file = ProjectAgentSnippet.targetFile(in: directory)
            let existing = try? String(contentsOf: file, encoding: .utf8)
            return Result { () throws(ProjectAgentSnippet.SnippetError) in
                (file, try ProjectAgentSnippet.apply(to: existing))
            }
        }.value
        switch result {
        case let .success((file, newText)):
            state = .snippetPreview(file: file, newText: newText)
        case let .failure(error):
            state = .failed(error.description)
        }
    }

    public func confirmSnippet() async {
        guard case let .snippetPreview(file, newText) = state else { return }
        state = .installing
        let error = await Task.detached { () -> String? in
            do {
                try Data(newText.utf8).write(to: file, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        state = error.map(State.failed) ?? .snippetWritten(file)
    }

    /// Cancel from a preview; applies nothing.
    public func cancel() {
        guard isConfirming else { return }
        state = .idle
    }
}
