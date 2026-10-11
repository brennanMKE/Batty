// StuckMouseReportGuard.swift

import Darwin
import Foundation

/// Decides whether a click on a Terminal Session must be withheld from the
/// surface because it would only type SGR mouse-report bytes at a shell prompt.
///
/// libghostty reports a click to the PTY whenever the surface's DEC mouse
/// tracking mode (9/1000/1002/1003) is set, and nothing clears that mode when the program that
/// set it dies without emitting its reset. The mode then outlives the program
/// and every click at the idle shell is typed into the line editor. The host
/// has no API to clear just the mouse mode on the exec backend (the `reset`
/// binding also wipes the screen), so the click is
/// withheld instead.
///
/// "Idle shell" means the PTY's foreground process group is led by a known
/// shell and holds no other process. A shell with job control puts every job
/// in its own group, so a group of one is the shell waiting at its prompt. A
/// non-interactive shell running a script shares its group with the programs
/// it starts while one is running (a builtin-only script alone in its group
/// is a rare false positive), and a program that owns the terminal (vim, htop, a command Tab
/// running a TUI directly) is not a shell by name, so their reports keep
/// flowing.
///
/// Shift-clicks are never withheld: Ghostty's `mouse-shift-capture` defaults to
/// off, so Shift-click and Shift-drag select locally even while mouse reporting
/// is on, which is the only way to select text in a Tab that left it on.
enum StuckMouseReportGuard {
    struct Process {
        var groupMembers: (pid_t) -> [pid_t]
        var name: (pid_t) -> String?

        static let live = Process(
            groupMembers: { pgid in
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
                var size = 0
                guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
                let stride = MemoryLayout<kinfo_proc>.stride
                var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
                size = procs.count * stride
                guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
                return procs.prefix(size / stride).map { $0.kp_proc.p_pid }
            },
            name: { pid in
                var buffer = [CChar](repeating: 0, count: 256)
                let length = proc_name(pid, &buffer, UInt32(buffer.count))
                guard length > 0 else { return nil }
                return String(cString: buffer)
            }
        )
    }

    /// Matched against `proc_name`, which reports `p_name`, falling back to `p_comm` (not argv[0]), so a
    /// login shell's leading "-" never appears. Unlike #0393's
    /// PlainShellKeyRewrite, fish is included: a withheld click is harmless
    /// there.
    static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "elvish",
    ]

    static func shouldWithholdClick(
        isMouseCaptured: Bool,
        foregroundPid: pid_t?,
        shiftHeld: Bool,
        process: Process = .live
    ) -> Bool {
        guard isMouseCaptured, !shiftHeld, let pid = foregroundPid, pid > 0 else { return false }
        guard process.groupMembers(pid) == [pid] else { return false }
        guard let name = process.name(pid) else { return false }
        return shellNames.contains(name)
    }
}
