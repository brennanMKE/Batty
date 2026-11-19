// CommandWaitShellTests.swift

import Foundation
import Testing
@testable import BattyKit

struct CommandWaitShellTests {
    @Test nonisolated func bashAndZshAreSupported() {
        for shell in ["/bin/zsh", "/opt/homebrew/bin/bash", "-zsh", "zsh -l"] {
            #expect(CommandWaitShell.supportsShellIntegration(shell), "\(shell)")
        }
    }

    @Test nonisolated func shellsWithoutIntegrationAreRefused() {
        for shell in ["/opt/homebrew/bin/fish", "elvish", "nu", "/bin/sh", "/usr/bin/env zsh", ""] {
            #expect(!CommandWaitShell.supportsShellIntegration(shell), "\(shell)")
        }
    }

    @Test @MainActor func singleLineAcceptsOneLineAndRejectsTwo() {
        #expect(CommandWaitShell.singleLine("make test") == "make test")
        #expect(CommandWaitShell.singleLine("make test\n") == "make test")
        #expect(CommandWaitShell.singleLine("a\nb") == nil)
        #expect(CommandWaitShell.singleLine("\n  \n") == nil)
    }
}
