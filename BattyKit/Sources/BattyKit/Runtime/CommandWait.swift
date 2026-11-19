// CommandWait.swift

import Foundation

/// `--wait` types its command into the user's shell and needs the shell's
/// OSC 133 D to learn the exit status; only bash and zsh have shell
/// integration in the vendored libghostty.
public nonisolated enum CommandWaitShell {
    public static func supportsShellIntegration(_ shell: String) -> Bool {
        guard let first = shell.split(whereSeparator: \.isWhitespace).first else { return false }
        var token = String(first)
        if token.hasPrefix("-") { token.removeFirst() }
        let name = (token as NSString).lastPathComponent
        return name == "bash" || name == "zsh"
    }

    public static func basename(_ shell: String) -> String {
        guard let first = shell.split(whereSeparator: \.isWhitespace).first else { return shell }
        var token = String(first)
        if token.hasPrefix("-") { token.removeFirst() }
        return (token as NSString).lastPathComponent
    }

    /// The command as the one line delivery would type, or nil unless it is
    /// exactly one line: each typed line yields its own OSC 133 D.
    @MainActor
    public static func singleLine(_ command: String) -> String? {
        let lines = StartupCommandDelivery.lines(from: command)
        return lines.count == 1 ? lines[0] : nil
    }
}

/// The Tab a ``CommandWaiter`` types into and listens to.
@MainActor
public protocol CommandWaitTab: AnyObject {
    func armCommand(_ line: String, events: @escaping (StartupCommandDeliveryEvent) -> Void)
    func addCommandFinishedEventObserver(_ observer: @escaping (Int?, UInt64) -> Void) -> UUID
    func removeCommandFinishedObserver(_ id: UUID)
    func addClosedObserver(_ handler: @escaping () -> Void) -> UUID
    func removeClosedObserver(_ id: UUID)
}

@MainActor
public final class TabRuntimeCommandWaitTab: CommandWaitTab {
    private let tab: TabRuntime
    private let hostStore: TerminalHostStore

    public init(tab: TabRuntime, hostStore: TerminalHostStore = .shared) {
        self.tab = tab
        self.hostStore = hostStore
    }

    public func armCommand(_ line: String, events: @escaping (StartupCommandDeliveryEvent) -> Void) {
        tab.armStartupCommand(line, events: events)
    }

    public func addCommandFinishedEventObserver(_ observer: @escaping (Int?, UInt64) -> Void) -> UUID {
        tab.addCommandFinishedEventObserver(observer)
    }

    public func removeCommandFinishedObserver(_ id: UUID) {
        tab.removeCommandFinishedObserver(id)
    }

    public func addClosedObserver(_ handler: @escaping () -> Void) -> UUID {
        hostStore.addReleaseObserver(forTabID: tab.id, handler)
    }

    public func removeClosedObserver(_ id: UUID) {
        hostStore.removeReleaseObserver(id)
    }
}

public enum CommandWaitOutcome: Equatable, Sendable {
    case exited(exitCode: Int?, durationNanos: UInt64)
    case timedOut
    case shellNotReady
    case notStarted
    case tabClosed
    case cancelled
}

@MainActor
public enum CommandWaiter {
    /// Types `line` into `tab`'s shell and returns when the first OSC 133 D
    /// after typing arrives, or another outcome ends the wait first. Never
    /// sends anything to the Tab after arming; the command keeps running on
    /// timeout and cancellation.
    public static func run(
        _ line: String,
        on tab: any CommandWaitTab,
        timeout: Duration,
        clock: any SchedulingClock
    ) async -> CommandWaitOutcome {
        let state = WaitState(tab: tab)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandWaitOutcome, Never>) in
                state.continuation = continuation
                if Task.isCancelled {
                    state.finish(.cancelled)
                    return
                }
                state.finishedToken = tab.addCommandFinishedEventObserver { [weak state] exitCode, duration in
                    guard let state, state.typed else { return }
                    state.finish(.exited(exitCode: exitCode, durationNanos: duration))
                }
                state.closedToken = tab.addClosedObserver { [weak state] in
                    state?.finish(.tabClosed)
                }
                state.timer = Task { @MainActor [weak state] in
                    await clock.sleep(for: timeout)
                    guard !Task.isCancelled, let state else { return }
                    state.finish(state.typed ? .timedOut : .shellNotReady)
                }
                tab.armCommand(line) { [weak state] event in
                    guard let state else { return }
                    switch event {
                    case .willType: state.typed = true
                    case .refused, .abandoned: state.finish(.notStarted)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in state.finish(.cancelled) }
        }
    }

    private final class WaitState: @unchecked Sendable {
        var continuation: CheckedContinuation<CommandWaitOutcome, Never>?
        var typed = false
        var resumed = false
        var finishedToken: UUID?
        var closedToken: UUID?
        var timer: Task<Void, Never>?
        let tab: any CommandWaitTab

        init(tab: any CommandWaitTab) {
            self.tab = tab
        }

        @MainActor
        func finish(_ outcome: CommandWaitOutcome) {
            guard !resumed, let continuation else { return }
            resumed = true
            if let finishedToken { tab.removeCommandFinishedObserver(finishedToken) }
            if let closedToken { tab.removeClosedObserver(closedToken) }
            timer?.cancel()
            timer = nil
            self.continuation = nil
            continuation.resume(returning: outcome)
        }
    }
}
