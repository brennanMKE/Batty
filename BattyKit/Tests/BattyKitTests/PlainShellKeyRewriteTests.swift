// PlainShellKeyRewriteTests.swift

import AppKit
import Foundation
import Testing
@testable import BattyKit

struct PlainShellKeyRewriteTests {
    private func rewritten(
        _ mods: NSEvent.ModifierFlags,
        keyCode: UInt16 = 36,
        process: String? = "zsh",
        members: Int = 1
    ) -> NSEvent.ModifierFlags? {
        PlainShellKeyRewrite.rewrittenModifiers(
            keyCode: keyCode, modifiers: mods, foregroundProcessName: process, foregroundGroupMemberCount: members)
    }

    @Test func shiftReturnAtShellPromptBecomesPlainReturn() {
        #expect(rewritten([.shift]) == [])
    }

    @Test func keypadEnterIsCovered() {
        #expect(rewritten([.shift, .numericPad], keyCode: 76) == [.numericPad])
    }

    @Test func controlAndShiftControlReturnAreCovered() {
        #expect(rewritten([.control]) == [])
        #expect(rewritten([.shift, .control]) == [])
    }

    @Test func unrelatedFlagsSurvive() {
        #expect(rewritten([.shift, .capsLock]) == [.capsLock])
    }

    @Test(arguments: ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh"])
    func everyPlainShellIsRecognised(name: String) {
        #expect(rewritten([.shift], process: name) == [])
    }

    @Test(arguments: ["claude", "node", "vim", "less", "fish", "nvim"])
    func extendedKeyProgramsKeepFullEncoding(name: String) {
        #expect(rewritten([.shift], process: name) == nil)
    }

    @Test(arguments: [0, 2, 5])
    func shellLedGroupWithOtherMembersIsLeftAlone(members: Int) {
        #expect(rewritten([.shift], process: "bash", members: members) == nil)
    }

    @Test func rewrittenEventKeepsKeyIdentity() throws {
        let original = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .capsLock], timestamp: 1,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: true, keyCode: 36))
        let result = PlainShellKeyRewrite.rewrittenEvent(from: original, modifiers: [.capsLock])
        #expect(result.keyCode == 36)
        #expect(result.isARepeat)
        #expect(result.characters == "\r")
        #expect(result.type == .keyDown)
        #expect(result.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.capsLock])
    }

    private func spawnSleeper(joiningGroup pgid: pid_t) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, pgid)
        var pid: pid_t = 0
        let args: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("30"), nil]
        defer { args.forEach { free($0) } }
        let status = posix_spawn(&pid, "/bin/sleep", nil, &attr, args, environ)
        try #require(status == 0)
        return pid
    }

    @Test func groupMemberCountIsExactForSingleAndMultiMemberGroups() throws {
        let leader = try spawnSleeper(joiningGroup: 0)
        let follower = try spawnSleeper(joiningGroup: leader)
        defer {
            kill(follower, SIGKILL)
            kill(leader, SIGKILL)
            var status: Int32 = 0
            waitpid(follower, &status, 0)
            waitpid(leader, &status, 0)
        }
        #expect(PlainShellKeyRewrite.groupMemberCount(of: leader) == 2)
        kill(follower, SIGKILL)
        var status: Int32 = 0
        waitpid(follower, &status, 0)
        #expect(PlainShellKeyRewrite.groupMemberCount(of: leader) == 1)
    }

    @Test func unknownForegroundProcessIsLeftAlone() {
        #expect(rewritten([.shift], process: nil) == nil)
    }

    @Test func unmodifiedReturnIsLeftAlone() {
        #expect(rewritten([]) == nil)
    }

    @Test func optionAndCommandReturnAreLeftAlone() {
        #expect(rewritten([.option]) == nil)
        #expect(rewritten([.shift, .option]) == nil)
        #expect(rewritten([.command]) == nil)
        #expect(rewritten([.shift, .command]) == nil)
    }

    @Test func otherKeysAreLeftAlone() {
        #expect(rewritten([.shift], keyCode: 48) == nil)
        #expect(rewritten([.shift], keyCode: 123) == nil)
    }

    @Test func processNameResolvesForCurrentProcess() {
        let name = PlainShellKeyRewrite.processName(of: getpid())
        #expect(name?.isEmpty == false)
    }
}
