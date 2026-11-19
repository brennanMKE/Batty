// AgentIntegrationModel.swift

import Foundation
import Observation

/// Drives Settings → Advanced's agent setup. Reads nothing until the user opens
/// Advanced, and writes nothing until the user confirms a preview.
@Observable
public final class AgentIntegrationModel {
    public enum State: Equatable {
        case idle
        case previewing(AgentInstallPlan)
        case previewingRemoval(AgentInstallPlan)
        case installing
        case finished(AgentInstallReport)
        case snippetPreview(file: URL, newText: String)
        case snippetWritten(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var statuses: [AgentHostStatus] = []
    public var selectedHosts: Set<AgentHost> = []
    /// Problems from the last install or refresh, for the caption under the host list.
    public private(set) var setupNote: String?

    @ObservationIgnored private let identity: @Sendable () -> AgentGuidanceIdentity?
    @ObservationIgnored private let installer: @Sendable () -> AgentGuidanceInstaller
    /// Records which hosts are installed, so later launches refresh only those.
    @ObservationIgnored private let recordStore: AgentSetupRecordStore?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        identity: @escaping @Sendable () -> AgentGuidanceIdentity?,
        installer: @escaping @Sendable () -> AgentGuidanceInstaller,
        recordStore: AgentSetupRecordStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identity = identity
        self.installer = installer
        self.recordStore = recordStore
        self.now = now
    }

    public convenience init() {
        self.init(identity: Self.liveIdentity, installer: Self.liveInstaller, recordStore: AgentSetupRecordStore(defaults: .standard))
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
        case .previewing, .previewingRemoval, .snippetPreview: true
        default: false
        }
    }

    /// Detection only: a `PATH` lookup and file-existence checks. No subprocess runs.
    public func loadStatus() async {
        let identity = identity
        let installer = installer
        let recordStore = recordStore
        let loaded = await Task.detached { () -> ([AgentHostStatus], String?) in
            let record = recordStore?.load()
            guard let identity = identity() else { return ([], nil) }
            let plan = installer().plan(identity: identity)
            let fingerprint = AgentGuidanceFingerprint.make(identity: identity) ?? ""
            let problems = record?.lastProblems ?? []
            return (AgentHostStatus.statuses(plan: plan, record: record, fingerprint: fingerprint), problems.isEmpty ? nil : problems.joined(separator: "\n"))
        }.value
        statuses = loaded.0
        setupNote = loaded.1
    }

    /// `nil` previews every detected host.
    public func beginInstall(hosts: Set<AgentHost>? = nil) async {
        let identity = identity
        let installer = installer
        let plan = await Task.detached { () -> AgentInstallPlan? in
            guard let identity = identity() else { return nil }
            let plan = installer().plan(identity: identity)
            return hosts.map(plan.restricted(to:)) ?? plan
        }.value
        guard let plan else {
            state = .failed(String(localized: "This build has no bundled agent guidance."))
            return
        }
        guard !plan.actions.isEmpty else { return }
        state = .previewing(plan)
    }

    public func confirmInstall() async {
        guard case let .previewing(plan) = state else { return }
        state = .installing
        let installer = installer
        let recordStore = recordStore
        let now = now
        let report = await Task.detached {
            let report = installer().apply(plan)
            if let recordStore {
                let fingerprint = AgentGuidanceFingerprint.make(identity: plan.identity)
                recordStore.save((recordStore.load() ?? AgentSetupRecord()).recording(plan: plan, report: report, fingerprint: fingerprint, at: now()))
            }
            return report
        }.value
        state = .finished(report)
        selectedHosts = []
        await loadStatus()
    }

    public func beginRemove(host: AgentHost) async {
        let identity = identity
        let installer = installer
        let plan = await Task.detached { () -> AgentInstallPlan? in
            identity().map { installer().removalPlan(identity: $0, hosts: [host]) }
        }.value
        guard let plan else {
            state = .failed(String(localized: "This build has no bundled agent guidance."))
            return
        }
        state = .previewingRemoval(plan)
    }

    public func confirmRemove() async {
        guard case let .previewingRemoval(plan) = state else { return }
        state = .installing
        let installer = installer
        let recordStore = recordStore
        let report = await Task.detached {
            let report = installer().apply(plan)
            if let recordStore {
                var record = (recordStore.load() ?? AgentSetupRecord()).removing(Set(plan.hosts))
                record.lastProblems = report.problemLines
                recordStore.save(record)
            }
            return report
        }.value
        state = .finished(report)
        await loadStatus()
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
