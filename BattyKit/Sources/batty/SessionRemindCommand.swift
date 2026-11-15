// SessionRemindCommand.swift

import ArgumentParser
import BattyCLICore
import BattyXPCCore
import Foundation

/// `batty session remind` (#0567): sets, replaces or cancels the target
/// Session's Reminder over XPC, the same model the GUI writes.
struct SessionRemindCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remind",
        abstract: "Set, replace or cancel a session's Reminder.",
        discussion: """
        Give the text to be reminded of as an argument (or with --note), and \
        exactly one of --in, --tomorrow, --at or --cancel. --in takes a \
        duration like 5m, 2h or 1h30m (1 minute to 7 days). --at HH:MM \
        (24-hour) alone fires later today. --tomorrow fires tomorrow at --at \
        HH:MM, or, when --at is omitted, at the app's Tomorrow time: the last \
        Tomorrow time chosen in the Reminder bar's Pick Date & Time…, 9:00 AM \
        until one is chosen. Setting a Reminder replaces any existing one; \
        --cancel succeeds quietly when none is pending. An unknown session id \
        exits 4.
        """,
        helpNames: .long
    )

    static let exactlyOneMessage = "specify exactly one of --in, --tomorrow, --at or --cancel"
    static let noteWithCancelMessage = "the text or --note is not valid with --cancel"
    static let textTwiceMessage = "give the text once: as an argument or with --note"
    static let inFormatMessage = "--in must be like 5m, 2h or 1h30m, between 1 minute and 7 days"
    static let atFormatMessage = "--at must be HH:MM, 24-hour"

    @Argument(help: "What to be reminded of (trimmed, up to 500 characters).")
    var text: String?

    @Option(name: .long, help: "Session id to remind. Falls back to BATTY_SESSION_ID, then the focused session, when omitted.")
    var session: String?

    @Option(name: .customLong("in"), help: "Fire after a duration: 5m, 2h or 1h30m (1 minute to 7 days).")
    var `in`: String?

    @Flag(name: .long, help: "Fire tomorrow, at --at or the app's default Tomorrow time.")
    var tomorrow = false

    @Option(name: .long, help: "HH:MM 24-hour: later today, or the time for --tomorrow.")
    var at: String?

    @Flag(name: .long, help: "Cancel the session's pending Reminder, if any.")
    var cancel = false

    @Option(name: .long, help: "The text, as an option (same as the argument; trimmed, up to 500 characters).")
    var note: String?

    @Flag(name: .long, help: "Emit JSON instead of a plain-text confirmation.")
    var json = false

    func validate() throws {
        guard [`in` != nil, tomorrow, at != nil && !tomorrow, cancel].filter({ $0 }).count == 1 else {
            throw ValidationError(Self.exactlyOneMessage)
        }
        if text != nil, note != nil { throw ValidationError(Self.textTwiceMessage) }
        if text != nil || note != nil, cancel { throw ValidationError(Self.noteWithCancelMessage) }
        if let duration = `in`, SessionRemindRequest.parseDuration(duration) == nil {
            throw ValidationError(Self.inFormatMessage)
        }
        if let at, SessionRemindTimeOfDay.parse(at) == nil {
            throw ValidationError(Self.atFormatMessage)
        }
    }

    /// Only called after `validate()`, so the parses succeed.
    nonisolated func makeRequest(sessionID: UUID?) -> SessionRemindRequest {
        let action: SessionRemindAction
        if cancel {
            action = .cancel
        } else if tomorrow {
            action = .tomorrow(time: at.flatMap(SessionRemindTimeOfDay.parse))
        } else if let time = at.flatMap(SessionRemindTimeOfDay.parse) {
            action = .today(time: time)
        } else {
            action = .after(minutes: `in`.flatMap(SessionRemindRequest.parseDuration) ?? 0)
        }
        return SessionRemindRequest(sessionID: sessionID, action: action, note: cancel ? nil : text ?? note)
    }

    /// Nil for a cancel reply, which prints nothing.
    nonisolated static func confirmationText(for reply: SessionRemindReply, calendar: Calendar, locale: Locale) -> String? {
        guard let reminder = reply.reminder else { return nil }
        var text: String
        if let dueAt = reminder.dueAt, let date = try? Date.ISO8601FormatStyle().parse(dueAt) {
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).month(.abbreviated).day().hour().minute()
            style.calendar = calendar
            text = "Reminder set for \(date.formatted(style))"
        } else {
            text = "Reminder set"
        }
        if let note = reminder.note { text += " — \(note)" }
        return text
    }

    nonisolated func run() throws {
        let request = makeRequest(sessionID: try resolveTargetSessionID(flag: session))

        switch AppConnectDance.resolveEndpoint() {
        case .failure(.brokerUnreachable):
            fputs("batty: broker unreachable\n", stderr)
            throw ExitCode(XPCExitCode.brokerUnreachable)
        case .failure(.appUnavailable):
            fputs("batty: app unavailable\n", stderr)
            throw ExitCode(XPCExitCode.appUnavailable)
        case .failure(.appRunningUnregistered):
            fputs("batty: Batty is running but isn't responding to the broker — try relaunching it\n", stderr)
            throw ExitCode(XPCExitCode.appRunningUnregistered)
        case .failure(.appBundleUnresolved(let message)):
            fputs("batty: \(message)\n", stderr)
            throw ExitCode(XPCExitCode.appBundleUnresolved)
        case .success(let endpoint):
            switch AppServiceClient.sessionRemind(endpoint: endpoint, request: request, timeout: 3.0) {
            case .success(let reply):
                if json {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    guard let data = try? encoder.encode(reply), let text = String(data: data, encoding: .utf8) else {
                        fputs("batty: failed to encode reminder as JSON\n", stderr)
                        throw ExitCode.failure
                    }
                    print(text)
                } else if let text = Self.confirmationText(for: reply, calendar: .current, locale: .current) {
                    print(text)
                }
            case .unreachable:
                fputs("batty: app unavailable\n", stderr)
                throw ExitCode(XPCExitCode.appUnavailable)
            case .requestFailed(let message):
                fputs("batty: request failed — \(message)\n", stderr)
                throw ExitCode(XPCExitCode.requestFailed)
            case .appTerminated:
                fputs("batty: app terminated\n", stderr)
                throw ExitCode(XPCExitCode.sessionTerminated)
            }
        }
    }
}

extension SessionRemindCommand: CapabilitiesDescribable {
    nonisolated static var capabilitiesInputSchema: CapabilitiesInputSchemaPayload {
        CapabilitiesInputSchemaPayload(
            properties: [
                "text": CapabilitiesPropertyPayload(cliKind: .positional, type: "string", description: "What to be reminded of (trimmed, up to 500 characters).", required: false),
                "session": CapabilitiesPropertyPayload(cliKind: .option, names: ["--session"], type: "string", description: "Session id to remind. Falls back to BATTY_SESSION_ID, then the focused session, when omitted.", required: false),
                "in": CapabilitiesPropertyPayload(cliKind: .option, names: ["--in"], type: "string", description: "Fire after a duration: 5m, 2h or 1h30m (1 minute to 7 days).", required: false),
                "tomorrow": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--tomorrow"], type: "boolean", description: "Fire tomorrow, at --at or the app's default Tomorrow time.", required: false, defaultValue: "false"),
                "at": CapabilitiesPropertyPayload(cliKind: .option, names: ["--at"], type: "string", description: "HH:MM 24-hour: later today, or the time for --tomorrow.", required: false),
                "cancel": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--cancel"], type: "boolean", description: "Cancel the session's pending Reminder, if any.", required: false, defaultValue: "false"),
                "note": CapabilitiesPropertyPayload(cliKind: .option, names: ["--note"], type: "string", description: "The text, as an option (same as the argument; trimmed, up to 500 characters).", required: false),
                "json": CapabilitiesPropertyPayload(cliKind: .flag, names: ["--json"], type: "boolean", description: "Emit JSON instead of a plain-text confirmation.", required: false, defaultValue: "false"),
            ],
            conflicts: [
                .mutuallyExclusive(["in", "tomorrow", "cancel"], description: exactlyOneMessage),
                .mutuallyExclusive(["in", "at", "cancel"], description: exactlyOneMessage),
                .mutuallyExclusive(["text", "note"], description: textTwiceMessage),
                .mutuallyExclusive(["text", "cancel"], description: noteWithCancelMessage),
                .mutuallyExclusive(["note", "cancel"], description: noteWithCancelMessage),
            ]
        )
    }
}
