// PlainShellKeyRewrite.swift

import AppKit
import Darwin
import Foundation
import GhosttyTerminal

/// Downgrades Shift-, Ctrl- and Command-modified Return to a plain Return
/// while a lone interactive shell is the pty's foreground process group.
/// Chords that include Option are left alone.
///
/// libghostty's legacy encoder maps modified Return to `CSI 27;<mods>;13~`
/// unconditionally (its function-key table has no mode gate for these
/// modifiers), and zsh/bash readline have no binding for it, so the tail of
/// the sequence self-inserts. Terminal.app sends a plain CR here. The rewrite applies only
/// when the foreground process group's leader is a plain shell and the group
/// has no other member, so a program started by a non-interactive wrapper
/// script (which shares the script's group) keeps the full encoding.
public enum PlainShellKeyRewrite {
    public static let returnKeyCodes: Set<UInt16> = [36, 76]

    public static let plainShellNames: Set<String> = [
        "zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh",
    ]

    private static let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    public static func rewrittenModifiers(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        foregroundProcessName: String?,
        foregroundGroupMemberCount: Int
    ) -> NSEvent.ModifierFlags? {
        guard returnKeyCodes.contains(keyCode) else { return nil }
        guard let modified = strippedModifiers(modifiers) else { return nil }
        guard foregroundGroupMemberCount == 1,
              let foregroundProcessName,
              plainShellNames.contains(foregroundProcessName)
        else { return nil }
        return modified
    }

    private static func strippedModifiers(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let held = modifiers.intersection(relevantFlags)
        guard !held.isEmpty, held.isSubset(of: [.shift, .control, .command]) else { return nil }
        return modifiers.subtracting([.shift, .control, .command])
    }

    public static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `proc_listpgrppids` returns the number of pids it wrote, not bytes, and
    /// a sizing call with a nil buffer returns a large over-estimate, so the
    /// list is read into a real buffer. Counts at most 8 members.
    public static func groupMemberCount(of pgid: pid_t) -> Int {
        var pids = [pid_t](repeating: 0, count: 8)
        let count = proc_listpgrppids(pgid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return max(0, Int(count))
    }

    public static func rewrittenEvent(from event: NSEvent, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: modifiers,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    @MainActor
    public static func rewrite(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, returnKeyCodes.contains(event.keyCode),
              let modifiers = strippedModifiers(event.modifierFlags)
        else { return event }
        guard let view = event.window?.firstResponder as? AppTerminalView,
              !view.hasMarkedText(),
              let pid = view.foregroundPid
        else { return event }
        guard rewrittenModifiers(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            foregroundProcessName: processName(of: pid),
            foregroundGroupMemberCount: groupMemberCount(of: pid)
        ) != nil else { return event }
        return rewrittenEvent(from: event, modifiers: modifiers)
    }
}
