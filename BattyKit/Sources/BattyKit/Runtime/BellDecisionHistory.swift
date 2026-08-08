// BellDecisionHistory.swift

import Foundation

/// #0297: which of the three real-bell trigger paths (or the #0290 system
/// entry, which never reaches this history — it's routed separately by
/// `AppStateStore.recordFootprintWarning` and never calls
/// `postNotification`) produced a given `BellFeedEntry`. Not persisted on
/// the entry itself. Internal, not `public`: nothing outside `BattyKit`
/// constructs or reads one directly.
enum BellTriggerKind: String, Sendable, Equatable {
    case bel
    case oscNotification
    case cliNotification
}

/// One bell-triggered notification decision, in a form a unit test can
/// build and inspect without touching `UNUserNotificationCenter`,
/// `NSApplication`, or `BellDecisionHistory`. `AppStateStore
/// .postNotification` constructs one of these on every call and hands it
/// to `AppStateStore.bellDecisionHistory.record(_:)` — one bell = one
/// record.
///
/// Timing note (#0288): for a Tab in a non-key/occluded window, the BEL
/// that produced this record may have been delivered by
/// `OccludedSurfaceTicker`'s 500 ms poll rather than a live callback, so
/// `bellTimestamp` (when the bell actually happened, per
/// `BellFeedEntry.timestamp`) can lag up to 500 ms behind when this record
/// was actually captured. `BellDecisionFormat` includes `bellTimestamp` in
/// the export text specifically so that skew is visible rather than merely
/// documented here.
struct BellDecisionRecord: Sendable, Equatable {
    enum SuppressionReason: String, Sendable, Equatable {
        /// `AppStateStore.notifier` is nil — no `BellNotifier` wired up
        /// (e.g. most unit tests construct `AppStateStore` without one).
        case nilNotifier
        /// `location.session.notificationsMuted` — per-Session mute.
        case sessionMuted
        /// `SettingsPreference.resolvedSystemNotifications()` is off.
        case systemNotificationsDisabled
        /// `BellNotifier.evaluateShouldPost` declined: Batty is frontmost
        /// and the entry was already seen at creation.
        case frontmostAndSeen
        /// #0298: this bell was a redundant repeat of a still-unread Bell
        /// Feed entry (same `tabID`, identical `message`, within
        /// `BellFeedStore.collapseWindow`) and was folded into that entry
        /// (`BellFeedStore.recordOrCollapse`'s `.collapsed` case) instead
        /// of becoming its own row. Recorded so the #0297 export keeps
        /// telling the truth about every bell rather than a collapsed
        /// repeat silently vanishing from the log, and so a future round
        /// can validate this rule against real traffic the same way this
        /// one was chosen. Takes priority over the notifier-gate reasons
        /// below in `AppStateStore.makeBellDecisionRecord` — a collapsed
        /// repeat never reaches `notifier.post` at all, so those gates
        /// were never evaluated for it.
        case collapsedIntoUnread
    }

    enum Outcome: Sendable, Equatable {
        /// Handed to `UNUserNotificationCenter.add` — *submitted*, not
        /// necessarily seen. Focus modes, Notification Summary, and
        /// per-app notification settings the user set outside Batty can
        /// all still hold or drop it downstream of this point, so treat
        /// this as "Batty tried," not as ground truth that the user saw a
        /// banner.
        case submitted
        case suppressed(SuppressionReason)
    }

    let trigger: BellTriggerKind
    let entryID: UUID
    let windowID: UUID
    let sessionID: UUID
    let paneID: UUID
    let tabID: UUID
    /// `BellFeedEntry.timestamp` — when the bell actually happened, not
    /// when this record was captured. See the #0288 timing note above.
    let bellTimestamp: Date
    /// Bounded to `BellDecisionFormat.maxFieldLength` raw characters by
    /// `AppStateStore.makeBellDecisionRecord` at construction — round-2
    /// review found the untruncated fields dead weight (retained ×1000,
    /// for the process lifetime, when `format(_:)` never renders more than
    /// `maxFieldLength` characters of any of the three anyway). See
    /// `BellDecisionFormat.truncateForRetention`'s doc comment for why
    /// truncating here is provably lossless with respect to the export.
    let sessionTitle: String
    /// Bounded the same way as `sessionTitle`; see that field's comment.
    let tabLabel: String
    let hasMessage: Bool
    /// Bounded the same way as `sessionTitle`; see that field's comment.
    let message: String?
    let battyActive: Bool
    let entrySeenAtCreation: Bool
    let notifierPresent: Bool
    let sessionMuted: Bool
    let systemNotificationsEnabled: Bool
    /// `TabRuntime.terminalNSView?.foregroundPid` — `tcgetpgrp` on the pty,
    /// nil until the surface has a process. This is the foreground process
    /// *group* at the moment of capture, which for a bell delivered late
    /// (see the #0288 timing note on the type doc comment) may no longer be
    /// the process that actually rang the bell.
    let foregroundPid: Int32?
    /// `TabRuntime.terminalNSView?.ttyName` (e.g. `/dev/ttys004`) — nil
    /// until the surface has a process. A device path, not user-authored
    /// content.
    let ttyName: String?
    let outcome: Outcome

    /// Pure decision function mirroring the real control flow across
    /// `AppStateStore.postNotification` and `BellNotifier.post` /
    /// `shouldPost`, in the same gate order those two methods evaluate
    /// them. Exists so the reported outcome can be asserted in a unit test
    /// without exercising the real posting path (which has side effects:
    /// `UNUserNotificationCenter.add`, sound playback).
    ///
    /// This mirrors those gates by construction rather than sharing a
    /// single implementation with them (only `evaluateShouldPost` is
    /// actually shared) — see the pointer comment on `BellNotifier.post`
    /// for the maintenance obligation that creates.
    static func outcome(
        notifierPresent: Bool,
        sessionMuted: Bool,
        systemNotificationsEnabled: Bool,
        battyActive: Bool,
        entrySeenAtCreation: Bool
    ) -> Outcome {
        guard notifierPresent else { return .suppressed(.nilNotifier) }
        guard !sessionMuted else { return .suppressed(.sessionMuted) }
        guard systemNotificationsEnabled else { return .suppressed(.systemNotificationsDisabled) }
        guard BellNotifier.evaluateShouldPost(isBattyActive: battyActive, entrySeen: entrySeenAtCreation) else {
            return .suppressed(.frontmostAndSeen)
        }
        return .submitted
    }
}

/// In-memory ring buffer of the most recent `BellDecisionHistory.capacity`
/// bell/notification decisions.
///
/// #0297's design went through two rounds before landing here. Round 1
/// shipped an always-on `Logger` line, hashed for privacy; round-1 review
/// (correctly) called that self-defeating — a hash with no stable join key
/// tells the user "something is noisy" and nothing about what. Round 2
/// fixed the privacy direction (log verbatim) but kept persisting to the
/// unified log, which meant the privacy question never actually went away,
/// just moved. The user redirected to this design instead: **keep nothing
/// anywhere the user didn't explicitly put it.** An in-memory ring that
/// never touches disk or the unified log has no privacy question left to
/// answer, so collection is unconditional (no Settings toggle, unlike the
/// round-1/2 designs) — the user's use case is retrospective ("I've been
/// getting junk notifications"), and a toggle defaulting off guarantees an
/// empty buffer at exactly the moment they reach for it. Settings UI
/// (`BellDecisionExportRow` in `SettingsView.swift`) is the only way this
/// data leaves the process: Copy to the pasteboard, Save to a
/// user-chosen file via `NSSavePanel`, or Clear.
///
/// `@Observable` so the Settings row's live count
/// (`"N of 1000 collected"`) and button-enabled state update as bells
/// arrive while Settings is open, the same way `BellFeedStore` (also
/// `@Observable`, held the same way on `AppStateStore`) drives the Bell
/// Feed popover.
@Observable
@MainActor
final class BellDecisionHistory {
    static let capacity = 1000

    private(set) var records: [BellDecisionRecord] = []

    init() {}

    /// Appends `record`, evicting the oldest entry once over `capacity`.
    /// Newest-last storage (append, not insert-at-0) keeps this an O(1)
    /// amortized append on the common path; `BellDecisionFormat
    /// .exportText` reverses for newest-first display, matching the Bell
    /// Feed's own newest-first convention (`BellFeedStore.record` inserts
    /// at index 0).
    func record(_ record: BellDecisionRecord) {
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    func clear() {
        records.removeAll()
    }
}

/// Pure formatting for `BellDecisionRecord` — no I/O, no logging, nothing
/// stateful. `BellDecisionHistory` owns *what* is retained; this owns how
/// it's rendered for `BellDecisionExportRow`'s Copy/Save actions.
enum BellDecisionFormat {
    /// One line per decision, newest first (matching `BellFeedStore`'s own
    /// convention), in `format(_:)`'s field order — greppable, sortable,
    /// and pasteable into an editor. Preceded by a one-line `#`-comment
    /// header so a saved file is self-describing out of context (why
    /// `bellAt` is UTC while a filename timestamp is local, how many
    /// records, when exported) without needing this doc comment alongside
    /// it. Empty when `records` is empty — no header, no lone empty line —
    /// so `Copy`/`Save to File…` can disable themselves on `text.isEmpty`
    /// without special-casing (in practice both buttons are already
    /// disabled whenever `records` is empty, so this is a defensive
    /// invariant more than a load-bearing one).
    static func exportText(_ records: [BellDecisionRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let header = "# batty bell decisions — exported \(Date().ISO8601Format()), \(records.count) record(s), bellAt in UTC"
        let body = records.reversed().map(format).joined(separator: "\n")
        return header + "\n" + body
    }

    /// Composes one record as one line, with `sessionTitle`, `tabLabel`,
    /// and `message` verbatim — quoted and escaped, not hashed. #0297
    /// exists so a user who is getting spammed can trace a line back to
    /// which program rang the bell; those three fields, as written, are
    /// the only ones that answer "what is this." Session/Pane/Tab UUIDs
    /// are not persisted anywhere between launches (no workspace
    /// persistence for the layout tree yet), so they cannot serve as a
    /// join key for a retrospective complaint the way the text itself can.
    /// `stableDigest` is kept alongside as a *secondary* field for
    /// clustering when a title is expected to churn (e.g. a prompt
    /// embedding a timestamp) — not as a substitute for the literal text.
    ///
    /// Verbatim text here is safe because this only ever reaches the user
    /// who deliberately pressed Copy or Save on their own machine, about
    /// their own terminal — see `BellDecisionHistory`'s type doc comment
    /// for why nothing is written anywhere else.
    static func format(_ record: BellDecisionRecord) -> String {
        let displayedMessage = record.hasMessage ? record.message : nil
        return """
        bellDecision trigger=\(record.trigger.rawValue) \
        entry=\(record.entryID) window=\(record.windowID) session=\(record.sessionID) \
        pane=\(record.paneID) tab=\(record.tabID) \
        bellAt=\(record.bellTimestamp.ISO8601Format()) \
        sessionTitle=\(quotedField(record.sessionTitle)) sessionTitleDigest=\(stableDigest(record.sessionTitle)) \
        tabLabel=\(quotedField(record.tabLabel)) tabLabelDigest=\(stableDigest(record.tabLabel)) \
        hasMessage=\(record.hasMessage) message=\(displayedMessage.map { quotedField($0) } ?? "nil") \
        messageDigest=\(displayedMessage.map(stableDigest) ?? "nil") \
        battyActive=\(record.battyActive) seenAtCreation=\(record.entrySeenAtCreation) \
        notifierPresent=\(record.notifierPresent) sessionMuted=\(record.sessionMuted) \
        systemNotificationsEnabled=\(record.systemNotificationsEnabled) \
        foregroundPid=\(record.foregroundPid.map(String.init) ?? "nil") tty=\(record.ttyName ?? "nil") \
        outcome=\(outcomeLabel(record.outcome))
        """
    }

    static func outcomeLabel(_ outcome: BellDecisionRecord.Outcome) -> String {
        switch outcome {
        case .submitted:
            return "submitted"
        case .suppressed(let reason):
            return "suppressed:\(reason.rawValue)"
        }
    }

    /// Longest a single quoted field is allowed to be before truncation —
    /// bounds a pathological OSC 777 body (or a title an unfriendly
    /// program sets) so it can't blow up a line. Applied after escaping,
    /// on the escaped text, so a run of quotes/backslashes right at the
    /// boundary can't produce an unterminated field. Also the bound
    /// `truncateForRetention` applies to a `BellDecisionRecord`'s raw
    /// fields at construction — see that function's doc comment for why
    /// the same number does double duty.
    static let maxFieldLength = 500

    /// Wraps `text` in double quotes with `\`, `"`, and newlines escaped,
    /// truncating only if `text` genuinely doesn't fit. The escaping is
    /// load-bearing: `AppStateStore.formatNotifyMessage` joins a CLI
    /// `notify` title and body with `"\n"`, so an unescaped multi-line
    /// `message` would split across export lines and break the
    /// one-line-per-decision invariant the whole point of the export
    /// (grep/sort in a text editor) depends on.
    ///
    /// The truncation check runs *before* appending each escaped unit, not
    /// after: checking after (the original round-2 shape) fired on a field
    /// whose escaped length landed exactly on `maxLength` with nothing left
    /// to truncate, appending a false `…` marker for data that was, in
    /// fact, complete. Checking before means the marker only ever appears
    /// when a character was genuinely dropped.
    static func quotedField(_ text: String, maxLength: Int = maxFieldLength) -> String {
        var escaped = ""
        var didTruncate = false
        for char in text {
            if escaped.count >= maxLength {
                didTruncate = true
                break
            }
            switch char {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.append(char)
            }
        }
        if didTruncate {
            escaped += "…"
        }
        return "\"\(escaped)\""
    }

    /// Bounds a `BellDecisionRecord`'s raw `sessionTitle`/`tabLabel`/
    /// `message` at construction time (`AppStateStore
    /// .makeBellDecisionRecord`), not just at format time. `BellDecisionRecord`
    /// has exactly one consumer — `format(_:)` — and `quotedField` never
    /// renders more than `maxLength` escaped characters of any field, so
    /// retaining more than that many raw characters per record is dead
    /// weight: up to `BellDecisionHistory.capacity` records, held for the
    /// process lifetime, with nothing bounding an OSC 9/777 body or a CLI
    /// `notify` body upstream of this call.
    ///
    /// Truncating the *raw* string here at `maxLength` is lossless with
    /// respect to the export: escaping only ever expands a character
    /// (`\` -> `\\`, `"` -> `\"`, a newline -> `\n`), so `maxLength` raw
    /// characters can never render as *fewer* than `maxLength` escaped
    /// ones — nothing past that raw offset could have survived
    /// `quotedField`'s own truncation either. `stableDigest`, computed
    /// after this truncation, therefore digests at most the first
    /// `maxLength` characters — still a stable, still-clustering digest,
    /// just cheaper to compute.
    static func truncateForRetention(_ text: String, maxLength: Int = maxFieldLength) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength))
    }

    /// Deterministic, non-cryptographic digest for a *secondary* clustering
    /// field alongside the verbatim text (see `format(_:)`'s doc comment
    /// for why the text itself is exported too). Not `String.hashValue`:
    /// Swift randomizes the hash seed per process launch (a DoS
    /// mitigation), so the same title would digest differently across
    /// restarts and break "the same title keeps firing" clustering — the
    /// entire point of hashing. FNV-1a is stable for identical input on
    /// any run, on any machine.
    static func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
