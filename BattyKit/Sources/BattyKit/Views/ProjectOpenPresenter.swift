// ProjectOpenPresenter.swift

import AppKit
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ProjectOpenPresenter")

/// The user-facing way to open a Project: through the startup-command trust
/// check, with a failure shown to the person who asked. Answering the trust
/// sheet with Escape reports `ProjectOpenError.cancelled`, which is a choice
/// and not an error, so it shows nothing.
@MainActor
enum ProjectOpenPresenter {
    static func shouldAlert(for error: Error) -> Bool {
        (error as? ProjectOpenError) != .cancelled
    }

    static func open(
        id: UUID,
        mode: AppStateStore.ProjectOpenMode,
        in store: AppStateStore,
        showError: @escaping @MainActor (Error) -> Void = { NSAlert(error: $0).runModal() }
    ) {
        store.requestOpenProject(id: id, mode: mode, completion: { result in
            guard case .failure(let error) = result, shouldAlert(for: error) else { return }
            logger.error("open project failed: \(error.localizedDescription, privacy: .public)")
            showError(error)
        })
    }
}
