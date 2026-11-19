// CommandWaitCLITests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct CommandWaitCLITests {
    @Test nonisolated func waitWithoutCommandIsRejected() {
        #expect(CommandWaitCLI.validationError(wait: true, timeout: nil, command: nil) == "--wait requires -c/--command")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: nil, command: "") == "--wait requires -c/--command")
    }

    @Test nonisolated func timeoutWithoutWaitIsRejected() {
        #expect(CommandWaitCLI.validationError(wait: false, timeout: 5, command: "ls") == "--timeout requires --wait")
    }

    @Test nonisolated func nonPositiveTimeoutIsRejected() {
        #expect(CommandWaitCLI.validationError(wait: true, timeout: 0, command: "ls") == "--timeout must be a positive number of seconds")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: -1, command: "ls") == "--timeout must be a positive number of seconds")
    }

    @Test nonisolated func nonFiniteAndHugeTimeoutsAreRejected() {
        #expect(CommandWaitCLI.validationError(wait: true, timeout: .infinity, command: "ls") == "--timeout must be a positive number of seconds")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: .nan, command: "ls") == "--timeout must be a positive number of seconds")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: 1e300, command: "ls") == "--timeout must be at most 86400 seconds")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: 86_401, command: "ls") == "--timeout must be at most 86400 seconds")
        #expect(CommandWaitCLI.validationError(wait: true, timeout: 86_400, command: "ls") == nil)
    }

    @Test nonisolated func parsingRejectsAnOutOfRangeTimeoutAsAUsageError() {
        do {
            _ = try TabNewCommand.parse(["-c", "true", "--wait", "--timeout", "inf"])
            Issue.record("tab new accepted --timeout inf")
        } catch {
            #expect(TabNewCommand.message(for: error) == "--timeout must be a positive number of seconds")
            #expect(TabNewCommand.exitCode(for: error) == .validationFailure)
        }
        do {
            _ = try PaneSplitCommand.parse(["-c", "true", "--wait", "--timeout", "1e300"])
            Issue.record("pane split accepted --timeout 1e300")
        } catch {
            #expect(PaneSplitCommand.message(for: error) == "--timeout must be at most 86400 seconds")
            #expect(PaneSplitCommand.exitCode(for: error) == .validationFailure)
        }
        #expect(throws: Never.self) { try TabNewCommand.parse(["-c", "true", "--wait", "--timeout", "86400"]) }
    }

    @Test nonisolated func timeoutPropertyAdvertisesTheMaximum() {
        #expect(CommandWaitCLI.waitProperties()["timeout"]?.maximum == 86_400)
        #expect(CommandWaitCLI.timeoutDescription.contains("86400"))
    }

    @Test nonisolated func multiLineCommandIsRejectedWithWait() {
        #expect(CommandWaitCLI.validationError(wait: true, timeout: nil, command: "a\nb") == "--wait needs a single-line command")
        #expect(CommandWaitCLI.validationError(wait: false, timeout: nil, command: "a\nb") == nil)
        #expect(CommandWaitCLI.validationError(wait: true, timeout: 30, command: "ls") == nil)
    }

    @Test nonisolated func exitZeroIsSuccess() {
        let outcome = CommandWaitCLI.exit(for: .exited, exitCode: 0, timeoutSeconds: 600)
        #expect(outcome.status == 0)
        #expect(outcome.message == nil)
    }

    @Test nonisolated func nonZeroExitIsStatus4WithTheCode() {
        let outcome = CommandWaitCLI.exit(for: .exited, exitCode: 3, timeoutSeconds: 600)
        #expect(outcome.status == 4)
        #expect(outcome.message == "command exited 3")
    }

    @Test nonisolated func missingExitCodeIsStatus4() {
        let outcome = CommandWaitCLI.exit(for: .exited, exitCode: nil, timeoutSeconds: 600)
        #expect(outcome.status == 4)
        #expect(outcome.message == "command finished without an exit status")
    }

    @Test nonisolated func timedOutSaysStillRunningAfterTheTimeout() {
        #expect(CommandWaitCLI.exit(for: .timedOut, exitCode: nil, timeoutSeconds: 3).message == "still running after 3 seconds")
        #expect(CommandWaitCLI.exit(for: .timedOut, exitCode: nil, timeoutSeconds: 2.5).message == "still running after 2.5 seconds")
        #expect(CommandWaitCLI.exit(for: .timedOut, exitCode: nil, timeoutSeconds: 3).status == 4)
    }

    @Test nonisolated func shellNotReadyNotStartedAndTabClosedAreStatus4() {
        for result in [CommandWaitResult.shellNotReady, .notStarted, .tabClosed] {
            let outcome = CommandWaitCLI.exit(for: result, exitCode: nil, timeoutSeconds: 10)
            #expect(outcome.status == 4)
            #expect(outcome.message?.isEmpty == false)
        }
    }

    @Test nonisolated func noWaitResultIsSuccess() {
        let outcome = CommandWaitCLI.exit(for: nil, exitCode: nil, timeoutSeconds: 600)
        #expect(outcome.status == 0)
        #expect(outcome.message == nil)
    }

    @Test nonisolated func clientTimeoutAddsSlackToTheWait() {
        #expect(CommandWaitCLI.clientTimeout(wait: false, timeout: nil) == 3.0)
        #expect(CommandWaitCLI.clientTimeout(wait: true, timeout: nil) == 610)
        #expect(CommandWaitCLI.clientTimeout(wait: true, timeout: 30) == 40)
    }
}
