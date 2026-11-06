// AppStateStore+BellCapture.swift

import Foundation

extension AppStateStore {
    /// Gate for every piece of capture work. When this is false the record
    /// paths do no snapshotting: no process lookup, no writer, no file.
    var isBellCaptureEnabled: Bool {
        SettingsPreference.resolvedCaptureBellFeedData(defaults: preferences)
    }

    /// Builds the `event` record from one occurrence and hands it to the
    /// writer's serial queue. For a collapsed repeat `entry` is the surviving
    /// feed entry, so it joins on the id the Bell Feed actually shows. When
    /// `feedRecorded` is false the entry was never added to the Bell Feed
    /// (#0555), so it is not marked captured.
    /// `decision` is the record `bellDecisionHistory` just received for this
    /// occurrence; its outcome and gate facts are reused, not recomputed.
    func captureBellEvent(
        entry: BellFeedEntry,
        at location: WindowRuntime.BellLocation,
        decision: BellDecisionRecord,
        collapsed: Bool,
        summarization: BellCaptureSummarization,
        feedRecorded: Bool
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
            tabTitle: location.tab.terminalTitle,
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
            feedRecorded: feedRecorded,
            feedRowPath: BellFeedEntry.pathLabel(sessionTitle: sessionTitle, paneIndex: paneIndex, tabLabel: tabLabel),
            feedRowText: entry.displayText,
            summarization: summarization
        ))
        if feedRecorded {
            bellFeed.markCaptured(entry.id)
        }
    }

    /// Deletes the capture files and forgets which entries were captured and
    /// rated, so the Bell Feed offers no rating for an entry whose `event`
    /// record is gone.
    public func clearBellCapture() {
        bellCaptureWriter?.clear()
        bellFeed.resetCaptureState()
    }

    public enum BellRatingAvailability: Equatable, Sendable {
        /// Capture is off, or the entry is the memory-footprint warning or a
        /// Reminder, which has no summary to rate.
        case hidden
        /// Capture is on but this entry has no `event` record.
        case notCaptured
        case available
    }

    public func bellRatingAvailability(for entry: BellFeedEntry) -> BellRatingAvailability {
        guard entry.kind == .bell, entry.sessionID != BellFeedEntry.systemID, isBellCaptureEnabled else { return .hidden }
        return bellFeed.capturedEntryIDs.contains(entry.id) ? .available : .notCaptured
    }

    /// Appends a `verdict` rating for `entryID`. Choosing the verdict an entry
    /// already has is a no-op: no record and no state write. `.cleared` on an
    /// entry with no verdict is likewise a no-op. Returns whether a record was
    /// enqueued.
    @discardableResult
    public func rateBellEntry(id entryID: UUID, verdict: BellRatingVerdict) -> Bool {
        let current = bellFeed.ratingVerdicts[entryID]
        if verdict == .cleared ? current == nil : current == verdict { return false }
        guard let entry = ratableEntry(id: entryID), let writer = bellCaptureWriter else { return false }
        writer.enqueue(Self.makeRating(snapshot: BellRatingSnapshot(entry), entryID: entryID, kind: .verdict, verdict: verdict, suggestedText: nil))
        bellFeed.setVerdict(verdict == .cleared ? nil : verdict, for: entryID)
        return true
    }

    /// What the row showed when the user picked Suggest Better Text…, taken
    /// then so the record describes what the suggestion was written against
    /// even if a summary lands while the editor is open. Nil when the entry
    /// can't be rated.
    public func bellRatingSnapshot(forEntryID entryID: UUID) -> BellRatingSnapshot? {
        ratableEntry(id: entryID).map(BellRatingSnapshot.init)
    }

    /// Appends a `suggestion` rating. Whitespace-only text is rejected; the
    /// text is stored trimmed. Each save appends a record; the latest wins.
    /// `snapshot` is the state captured when the editor opened; without one
    /// the entry's current state is used.
    @discardableResult
    public func suggestBellText(id entryID: UUID, text: String, snapshot: BellRatingSnapshot? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let entry = ratableEntry(id: entryID), let writer = bellCaptureWriter else { return false }
        writer.enqueue(Self.makeRating(
            snapshot: snapshot ?? BellRatingSnapshot(entry),
            entryID: entryID,
            kind: .suggestion,
            verdict: nil,
            suggestedText: trimmed
        ))
        return true
    }

    private func ratableEntry(id entryID: UUID) -> BellFeedEntry? {
        guard isBellCaptureEnabled,
              bellFeed.capturedEntryIDs.contains(entryID),
              let entry = bellFeed.entries.first(where: { $0.id == entryID }),
              entry.kind == .bell,
              entry.sessionID != BellFeedEntry.systemID
        else { return nil }
        return entry
    }

    static func makeRating(
        snapshot: BellRatingSnapshot,
        entryID: UUID,
        kind: BellRatingKind,
        verdict: BellRatingVerdict?,
        suggestedText: String?,
        now: Date = Date()
    ) -> BellCaptureRating {
        func capped(_ text: String?) -> String? {
            text.map { String($0.prefix(BellCaptureSchema.maxMessageCharacters)) }
        }
        return BellCaptureRating(
            entryID: entryID,
            ratedAt: now,
            kind: kind,
            verdict: verdict,
            suggestedText: capped(suggestedText),
            shownText: capped(snapshot.shownText),
            summaryAtRating: capped(snapshot.summary),
            messageAtRating: capped(snapshot.message)
        )
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
