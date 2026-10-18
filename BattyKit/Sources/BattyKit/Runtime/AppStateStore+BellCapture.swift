// AppStateStore+BellCapture.swift

import Foundation

extension AppStateStore {
    /// Gate for every piece of capture work. When this is false the record
    /// paths do no snapshotting: no process lookup, no writer, no file.
    var isBellCaptureEnabled: Bool {
        SettingsPreference.resolvedCaptureBellFeedData(defaults: preferences)
    }

    /// Builds the `event` record from one occurrence and hands it to the
    /// writer's serial queue. `entry` is the surviving feed entry, so a
    /// collapsed repeat joins on the id the Bell Feed actually shows.
    /// `decision` is the record `bellDecisionHistory` just received for this
    /// occurrence; its outcome and gate facts are reused, not recomputed.
    func captureBellEvent(
        entry: BellFeedEntry,
        at location: WindowRuntime.BellLocation,
        decision: BellDecisionRecord,
        collapsed: Bool,
        summarization: BellCaptureSummarization
    ) {
        guard let writer = bellCaptureWriter else { return }

        let paneIndex = (location.session.tree.allPanes.firstIndex { $0.id == location.pane.id } ?? 0) + 1
        let tabIndex = (location.pane.tabs.firstIndex { $0.id == location.tab.id } ?? 0) + 1
        let tabLabel = Self.tabLabel(for: location.tab, tabIndex: tabIndex)
        let sessionTitle = location.session.title

        let fullMessage = entry.message
        let messageTruncated = (fullMessage?.count ?? 0) > BellCaptureSchema.maxMessageCharacters
        let message = messageTruncated ? fullMessage.map { String($0.prefix(BellCaptureSchema.maxMessageCharacters)) } : fullMessage

        var process: BellCaptureProcess?
        if let pid = location.tab.terminalNSView?.foregroundPid, pid > 0 {
            let identity = ProcessInspector.identity(pid: pid)
            process = BellCaptureProcess(pid: pid, name: identity.name, executablePath: identity.executablePath)
        }

        let notification: BellCaptureNotification
        var notificationTitle: String?
        var notificationBody: String?
        switch decision.outcome {
        case .submitted:
            notification = BellCaptureNotification(outcome: "submitted", reason: nil)
            notificationTitle = BellNotifier.notificationTitle(sessionTitle: sessionTitle, paneIndex: paneIndex, tabLabel: tabLabel)
            notificationBody = BellNotifier.notificationBody(for: entry)
        case .suppressed(let reason):
            notification = BellCaptureNotification(outcome: "suppressed", reason: reason.rawValue)
        }

        let info = Bundle.main.infoDictionary
        writer.enqueue(BellCaptureEvent(
            entryID: entry.id,
            capturedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String,
            windowID: entry.windowID,
            sessionID: entry.sessionID,
            paneID: entry.paneID,
            tabID: entry.tabID,
            trigger: decision.trigger.rawValue,
            message: message,
            messageTruncated: messageTruncated,
            tabTitle: location.tab.terminal.title,
            tabLabel: tabLabel,
            sessionTitle: sessionTitle,
            foregroundProcess: process,
            workingDirectory: location.tab.workingDirectory,
            screen: nil,
            screenUnavailableReason: "unsupportedByTerminalHost",
            seenAtCreation: decision.entrySeenAtCreation,
            battyActive: decision.battyActive,
            sessionMuted: decision.sessionMuted,
            systemNotificationsEnabled: decision.systemNotificationsEnabled,
            notifierPresent: decision.notifierPresent,
            collapse: BellCaptureCollapse(collapsed: collapsed, repeatCount: entry.repeatCount, firstOccurrenceAt: entry.firstOccurrenceAt),
            notification: notification,
            notificationTitle: notificationTitle,
            notificationBody: notificationBody,
            feedRowPath: BellFeedEntry.pathLabel(sessionTitle: sessionTitle, paneIndex: paneIndex, tabLabel: tabLabel),
            feedRowText: entry.displayText,
            summarization: summarization
        ))
    }

    static func makeCaptureSummary(
        entryID: UUID,
        result: NotificationSummarizationResult,
        cancelled: Bool,
        sanitized: String?,
        elapsedSeconds: Double,
        feedRowText: String?
    ) -> BellCaptureSummary {
        var status: BellCaptureSummaryStatus
        var errorDescription: String?
        if cancelled {
            status = .cancelled
        } else if let failure = result.failure {
            switch failure {
            case .modelUnavailable: status = .modelUnavailable
            case .cancelled: status = .cancelled
            case .timedOut: status = .timedOut
            case .error(let description):
                status = .error
                errorDescription = description
            }
        } else if sanitized != nil {
            status = .ok
        } else if let raw = result.rawReply {
            let trimmed = NotificationSummary.trimmed(raw)
            status = trimmed.uppercased() == "NONE" || trimmed.isEmpty ? .none : .rejectedBySanitize
        } else {
            status = .error
            errorDescription = "summarizer returned neither a reply nor a failure"
        }
        return BellCaptureSummary(
            entryID: entryID,
            capturedAt: Date(),
            instructions: result.instructions,
            prompt: result.prompt,
            rawReply: result.rawReply,
            status: status,
            errorDescription: errorDescription,
            elapsedSeconds: elapsedSeconds,
            sanitizedSummary: sanitized,
            feedRowText: feedRowText
        )
    }
}
