// AppStateStore+ProjectStartup.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectStartup")

public struct ProjectStartupTrustRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let commandsHash: String
    public let rows: [ProjectStartupCommandRow]
}

struct PendingStartupOpen {
    var projectID: UUID
    var commandsHash: String
    var mode: AppStateStore.ProjectOpenMode
    var contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)?
    var completion: ((Result<AppStateStore.ProjectOpenResult, Error>) -> Void)?
}

extension AppStateStore {
    /// Opens a Project the way a user-facing entry point does: applies the
    /// startup-command policy (`ProjectStartupTrust`), asking first when the
    /// command set is new or has changed. `completion` runs once, when the
    /// Session exists or the open failed; if the user answers the sheet it
    /// runs after that answer, and with `ProjectOpenError.cancelled` if they
    /// dismiss it. Focusing a Project that is already open never prompts and
    /// never runs commands.
    ///
    /// Call from an event handler (menu, palette, sheet button, XPC
    /// request), never from `body`/`onAppear`: it appends to
    /// `WindowRuntime.pendingStartupTrusts`, which presents the sheet.
    public func requestOpenProject(
        id projectID: UUID,
        mode: ProjectOpenMode = .focusExistingOrOpen,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)? = nil,
        completion: ((Result<ProjectOpenResult, Error>) -> Void)? = nil
    ) {
        guard featureFlags.projects, let projectStore else {
            logger.notice("requestOpenProject: ignored; projects feature is off")
            completion?(.failure(ProjectOpenError.featureDisabled))
            return
        }
        guard let project = projectStore.project(id: projectID) else {
            logger.notice("requestOpenProject: unknown project id=\(projectID, privacy: .public)")
            completion?(.failure(ProjectOpenError.unknownProject(projectID)))
            return
        }
        let alreadyOpen = mode == .focusExistingOrOpen && openProjectIDs.contains(projectID)
        let decision = alreadyOpen ? ProjectStartupDecision.skip : ProjectStartupTrust.decide(project)
        switch decision {
        case .skip:
            finishOpen(project, mode: mode, contentFactory: contentFactory,
                       outcome: ProjectStartupOutcome(runCommands: false, hashToStore: nil), completion: completion)
        case .runWithoutPrompt:
            finishOpen(project, mode: mode, contentFactory: contentFactory,
                       outcome: ProjectStartupOutcome(runCommands: true, hashToStore: nil), completion: completion)
        case .prompt:
            guard let target = defaultTargetWindow() else {
                logger.error("requestOpenProject: no window available for the trust sheet")
                completion?(.failure(ProjectOpenError.noWindow))
                return
            }
            let request = ProjectStartupTrustRequest(
                id: UUID(),
                projectID: projectID,
                projectName: project.name,
                commandsHash: project.startupCommandsHash,
                rows: ProjectStartupTrust.rows(for: project)
            )
            pendingStartupOpens[request.id] = PendingStartupOpen(
                projectID: projectID, commandsHash: request.commandsHash, mode: mode, contentFactory: contentFactory, completion: completion)
            target.pendingStartupTrusts.append(request)
        }
    }

    /// The trust sheet's buttons. A request that is no longer pending (a
    /// double click, a closed window) is ignored.
    public func resolveStartupTrust(requestID: UUID, choice: ProjectStartupChoice) {
        guard let pending = takePendingStartupOpen(requestID: requestID) else { return }
        guard featureFlags.projects, let projectStore else {
            pending.completion?(.failure(ProjectOpenError.featureDisabled))
            return
        }
        guard let project = projectStore.project(id: pending.projectID) else {
            pending.completion?(.failure(ProjectOpenError.unknownProject(pending.projectID)))
            return
        }
        if case .run = choice,
           project.startupCommandsHash != pending.commandsHash || !project.runStartupCommandsOnOpen {
            logger.notice("resolveStartupTrust: commands or run toggle changed while the sheet was open; asking again")
            requestOpenProject(
                id: project.id, mode: pending.mode,
                contentFactory: pending.contentFactory, completion: pending.completion)
            return
        }
        finishOpen(
            project, mode: pending.mode, contentFactory: pending.contentFactory,
            outcome: ProjectStartupTrust.outcome(for: choice, project: project),
            completion: pending.completion)
    }

    /// The trust sheet was dismissed without a choice: nothing opens.
    public func cancelStartupTrust(requestID: UUID) {
        guard let pending = takePendingStartupOpen(requestID: requestID) else { return }
        pending.completion?(.failure(ProjectOpenError.cancelled))
    }

    private func takePendingStartupOpen(
        requestID: UUID
    ) -> PendingStartupOpen? {
        guard let request = pendingStartupOpens.removeValue(forKey: requestID) else { return nil }
        for window in windows {
            window.pendingStartupTrusts.removeAll { $0.id == requestID }
        }
        return request
    }

    private func finishOpen(
        _ project: Project,
        mode: ProjectOpenMode,
        contentFactory: (@MainActor (PaneContentKind) -> (any PaneContentLifecycle)?)?,
        outcome: ProjectStartupOutcome,
        completion: ((Result<ProjectOpenResult, Error>) -> Void)?
    ) {
        if let hash = outcome.hashToStore, let projectStore {
            var approved = project
            approved.approvedCommandsHash = hash
            do {
                try projectStore.upsert(approved)
            } catch {
                logger.error("could not store the approval hash: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            let result = try openProject(id: project.id, mode: mode, contentFactory: contentFactory)
            if result.wasCreated, outcome.runCommands {
                armStartupCommands(of: project, in: result.session)
            }
            completion?(.success(result))
        } catch {
            completion?(.failure(error))
        }
    }

    /// Arms each non-blank startup command on the Tab it belongs to. The
    /// commands type themselves in once that Tab's shell reports its first
    /// working directory.
    func armStartupCommands(of project: Project, in session: SessionRuntime) {
        guard featureFlags.projects else { return }
        let panes = session.tree.allPanes
        for entry in project.startupCommands {
            guard panes.indices.contains(entry.paneIndex),
                  panes[entry.paneIndex].kind == .terminal,
                  panes[entry.paneIndex].tabs.indices.contains(entry.tabIndex) else {
                logger.error("armStartupCommands: no Tab for pane=\(entry.paneIndex, privacy: .public) tab=\(entry.tabIndex, privacy: .public)")
                continue
            }
            let tab = panes[entry.paneIndex].tabs[entry.tabIndex]
            if let sink = startupInputSinkFactory?(tab) {
                tab.armStartupCommand(entry.command, sink: sink)
            } else {
                tab.armStartupCommand(entry.command)
            }
        }
    }
}
