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

    @Test func groupMemberCountIsExactForSingleAndMultiMemberGroups() throws {
        let leader = try TestChildSpawner.spawn("/bin/sleep", arguments: ["sleep", "30"], ownGroup: true)
        let follower = try TestChildSpawner.spawn("/bin/sleep", arguments: ["sleep", "30"], ownGroup: true, joiningGroup: leader.pid)
        defer {
            if follower.signal(SIGKILL) == 0 { follower.reapNow() }
            leader.signal(SIGKILL)
            leader.reapNow()
        }
        #expect(PlainShellKeyRewrite.groupMemberCount(of: leader.pid) == 2)
        follower.signal(SIGKILL)
        follower.reapNow()
        #expect(PlainShellKeyRewrite.groupMemberCount(of: leader.pid) == 1)
    }

    @Test func unknownForegroundProcessIsLeftAlone() {
        #expect(rewritten([.shift], process: nil) == nil)
    }

    @Test func unmodifiedReturnIsLeftAlone() {
        #expect(rewritten([]) == nil)
    }

    @Test func commandReturnBecomesPlainReturn() {
        #expect(rewritten([.command]) == [])
        #expect(rewritten([.command], process: "bash") == [])
    }

    @Test func commandShiftAndCommandControlReturnAreCovered() {
        #expect(rewritten([.shift, .command]) == [])
        #expect(rewritten([.control, .command]) == [])
        #expect(rewritten([.shift, .control, .command]) == [])
    }

    @Test func commandKeypadEnterIsCovered() {
        #expect(rewritten([.command, .numericPad], keyCode: 76) == [.numericPad])
    }

    @Test(arguments: ["claude", "vim", "fish"])
    func commandReturnKeepsModifiedKeyOutsideShell(name: String) {
        #expect(rewritten([.command], process: name) == nil)
    }

    @Test func commandReturnIsLeftAloneWithoutLoneShell() {
        #expect(rewritten([.command], process: nil) == nil)
        #expect(rewritten([.command], members: 2) == nil)
    }

    @Test func optionChordsAreLeftAlone() {
        #expect(rewritten([.option]) == nil)
        #expect(rewritten([.shift, .option]) == nil)
        #expect(rewritten([.command, .option]) == nil)
        #expect(rewritten([.command, .option, .shift]) == nil)
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
