// TerminalDelegateProxy.swift

import AppKit
import Foundation
import GhosttyTerminal
import OSLog

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "TerminalDelegateProxy")

final class TerminalDelegateProxy: NSObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    private let state: TerminalViewState
    private var didPushHoverCursor: Bool = false

    private(set) var hoveredURL: String?

    /// Fires on every working-directory change libghostty reports, with the
    /// newly-reported path. **Not** after that path has landed on `state`:
    /// `state.terminalDidChangeWorkingDirectory(path)` defers its write to
    /// the next main-queue turn (`publishSoon`, libghostty-spm), so at the
    /// point this closure runs, `state.workingDirectory` (and its mirrors,
    /// e.g. `TabRuntime.workingDirectory`) still hold the *previous* path.
    /// Consumers must use the `path` argument directly rather than reading
    /// `state`/`terminal.workingDirectory` back synchronously (#0436 — a
    /// prior version of this comment claimed the opposite ordering).
    /// The host wires this to drive session auto-naming directly, rather
    /// than relying on a SwiftUI `.onChange` over `state.workingDirectory` —
    /// that property is a Combine `@Published` on an `ObservableObject`,
    /// which the `@Observable` model layer does not track, so the
    /// view-driven path fired only opportunistically and left names stuck
    /// on the initial directory (#0226-adjacent; see #0227).
    var onWorkingDirectoryChange: ((String) -> Void)?

    /// Fires when a terminal program in this tab's Session needs the user's
    /// permission for a clipboard operation (unsafe paste, or a protected
    /// OSC 52 read/write). Wired by `PaneView` (which has the owning
    /// `SessionRuntime` this proxy doesn't) to
    /// `SessionRuntime.requestClipboardReadConfirmation(kind:decide:)`.
    /// If nothing has wired this yet, `resolveClipboardConfirmationRoute`
    /// denies immediately rather than leaving the request unanswered.
    ///
    /// Upstream's `TerminalClipboardConfirmationRequest` carries only
    /// `contents`/`kind` — no program name and no per-request `canRemember`
    /// flag (both existed in the C struct `ghostty_clipboard_confirm_s` but
    /// upstream's own Swift wrapper does not surface them to the host
    /// delegate). So Batty forwards just `kind`, plus a plain `Bool`
    /// completion that answers `request.respond(allow:)` — "remember" is
    /// now entirely a Batty-side, always-available policy rather than
    /// something upstream opts a request into or out of.
    var onClipboardReadConfirmationRequest: (
        (TerminalClipboardRequestKind, @escaping (Bool) -> Void) -> Void
    )?

    /// True once libghostty has reported any working directory. The first
    /// report (OSC 7 from the bundled shell integration's prompt hook) is
    /// the signal that the shell is up and drawing a prompt.
    private(set) var hasReportedWorkingDirectory = false

    private var pendingStartupCommand: StartupCommandDelivery?
    private var readinessClock: (any SchedulingClock)?
    /// The pending deadline, exposed so a test can await it after advancing
    /// its clock instead of guessing when the Task has run.
    private(set) var readinessDeadlineTask: Task<Void, Never>?
    private var hasAttachedSurface = false

    /// Set by the owning ``TabRuntime``; carried only into log lines.
    var tabID: UUID?

    /// Fires when the Tab enters (a value) or leaves (nil) the state of
    /// waiting on a startup command whose shell never reported readiness.
    /// Wired by ``TabRuntime``, which holds the observed copy of it.
    var onStartupWaitingChange: ((StartupCommandWaiting?) -> Void)?

    private(set) var startupWaiting: StartupCommandWaiting? {
        didSet { if startupWaiting != oldValue { onStartupWaitingChange?(startupWaiting) } }
    }

    /// Delivers `delivery` on the first working-directory report, or right
    /// away if one has already arrived (the pwd closure in
    /// ``onWorkingDirectoryChange`` is installed from a `.task` after mount,
    /// so a report can precede any consumer of it). Kept out of
    /// ``onWorkingDirectoryChange`` so it composes with auto-naming instead
    /// of competing for that single slot.
    ///
    /// A shell that never reports does not get the command typed blindly: it
    /// may be sitting at a password or login prompt. Once the surface has
    /// been attached for ``StartupCommandReadiness/deadline`` on `clock` with
    /// no report, the Tab enters ``startupWaiting`` and the delivery stays
    /// armed until a late report, ``runStartupCommandNow()`` or
    /// ``dismissStartupCommand()``.
    func armStartupCommand(
        _ delivery: StartupCommandDelivery,
        clock: any SchedulingClock = SystemClock()
    ) {
        if hasReportedWorkingDirectory || !delivery.hasCommand {
            delivery.deliverOnNextMainTurn()
            return
        }
        dismissStartupCommand()
        pendingStartupCommand = delivery
        readinessClock = clock
        if hasAttachedSurface { startReadinessDeadline() }
    }

    /// The deadline is measured from here, not from arming, so a Tab in a
    /// Session nobody has looked at yet is not penalised for never mounting.
    func surfaceDidAttach() {
        hasAttachedSurface = true
        if pendingStartupCommand != nil, readinessDeadlineTask == nil, startupWaiting == nil {
            startReadinessDeadline()
        }
    }

    /// Types the waiting command through the same delivery, so it still
    /// happens at most once however many reports follow.
    @discardableResult
    func runStartupCommandNow() -> StartupCommandDelivery? {
        guard let delivery = takePendingStartupCommand() else { return nil }
        delivery.deliverOnNextMainTurn()
        return delivery
    }

    func dismissStartupCommand() {
        takePendingStartupCommand()?.abandon()
    }

    private func takePendingStartupCommand() -> StartupCommandDelivery? {
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask = nil
        startupWaiting = nil
        let delivery = pendingStartupCommand
        pendingStartupCommand = nil
        return delivery
    }

    private func startReadinessDeadline() {
        guard let clock = readinessClock else { return }
        readinessDeadlineTask = Task { @MainActor [weak self] in
            await clock.sleep(for: StartupCommandReadiness.deadline)
            guard !Task.isCancelled else { return }
            self?.readinessDeadlineDidPass()
        }
    }

    private func readinessDeadlineDidPass() {
        readinessDeadlineTask = nil
        guard let delivery = pendingStartupCommand else { return }
        logger.notice("startup command waiting: tab=\(self.tabID?.uuidString ?? "unknown", privacy: .public) reason=deadline")
        startupWaiting = StartupCommandWaiting(command: delivery.commandText)
    }

    init(state: TerminalViewState) {
        self.state = state
    }

    deinit {
        readinessDeadlineTask?.cancel()
    }

    func terminalDidChangeTitle(_ title: String) {
        state.terminalDidChangeTitle(title)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        state.terminalDidResize(size)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        state.terminalDidChangeFocus(focused)
    }

    func terminalDidClose(processAlive: Bool) {
        if let abandoned = takePendingStartupCommand() {
            abandoned.abandon()
            logger.notice("startup command disarmed: tab=\(self.tabID?.uuidString ?? "unknown", privacy: .public) reason=shell exited before reporting readiness")
        }
        state.terminalDidClose(processAlive: processAlive)
    }

    func terminalDidRingBell() {
        state.terminalDidRingBell()
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        state.terminalDidRequestDesktopNotification(title: title, body: body)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        hasReportedWorkingDirectory = true
        state.terminalDidChangeWorkingDirectory(path)
        onWorkingDirectoryChange?(path)
        if let delivery = takePendingStartupCommand() {
            delivery.deliverOnNextMainTurn()
        }
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        state.terminalDidFinishCommand(exitCode: exitCode, durationNanos: durationNanos)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        state.terminalDidAttachSurface(surface)
        surfaceDidAttach()
    }

    func terminalDidDetachSurface() {
        state.terminalDidDetachSurface()
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        HyperlinkOpener.open(url)
    }

    func terminalDidRequestClipboardConfirmation(
        _ request: TerminalClipboardConfirmationRequest
    ) {
        resolveClipboardConfirmationRoute(kind: request.kind) { allowed in
            request.respond(allow: allowed)
        }
    }

    /// The fail-open leg this proxy must never get wrong: with no route
    /// wired, `respond` must be called with `false`, not left uncalled and
    /// not defaulted to `true`. Pulled out of
    /// `terminalDidRequestClipboardConfirmation` so it has direct test
    /// coverage — `TerminalClipboardConfirmationRequest`'s initializer is
    /// `internal` to `GhosttyTerminal`, so BattyKit tests cannot construct
    /// one to exercise the real delegate method directly.
    func resolveClipboardConfirmationRoute(
        kind: TerminalClipboardRequestKind,
        respond: @escaping (Bool) -> Void
    ) {
        guard let onClipboardReadConfirmationRequest else {
            logger.warning("clipboard confirmation with no route wired — denying")
            respond(false)
            return
        }
        onClipboardReadConfirmationRequest(kind, respond)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        hoveredURL = url
        if url != nil {
            if !didPushHoverCursor {
                NSCursor.pointingHand.push()
                didPushHoverCursor = true
            }
        } else if didPushHoverCursor {
            NSCursor.pop()
            didPushHoverCursor = false
        }
    }
}
