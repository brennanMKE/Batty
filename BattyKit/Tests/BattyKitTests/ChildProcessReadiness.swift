// ChildProcessReadiness.swift

import Darwin
import Foundation

/// Awaits a child process's "ready" signal as an event — a
/// `FileHandle.readabilityHandler` plus a checked continuation — instead of
/// blocking the calling thread on `availableData` with no upper bound (the
/// two copies this replaces, both #0427: `PendingTeardownReapRegistryTests
/// .waitForReady`, `ProcessGitStatusScannerTests.waitForReady`) or polling a
/// plain file's existence with `Thread.sleep`
/// (`LMStudioSIGTERMIgnoringFixture.waitForReadyFile`). Two entry points,
/// one shared mechanism underneath:
///
/// - **Pipe** (`waitForData(on:bound:)`): the test owns the child's stdout
///   directly — `PendingTeardownReapRegistryTests`, `ProcessGitStatusScannerTests`.
/// - **FIFO** (`waitForFIFOReady(at:bound:)`): the content's own factory
///   owns stdout, so the test can't attach its own `Pipe` — the child
///   writes into a `mkfifo` path instead (`LMStudioSIGTERMIgnoringFixture`).
///   Opened `O_NONBLOCK` so the read side never blocks waiting for the
///   child to open its write end (the child may not have spawned yet); the
///   same readability-handler path then waits for the write to actually
///   land.
///
/// Both take `bound` as a **hang guard only**: on expiry the wait resolves
/// `false`, and that is never how it normally succeeds. `ResumeOnce`
/// (`ResumeOnce.swift`) guarantees the handler is cleared and the
/// continuation resumed exactly once regardless of which path wins the
/// race — data, EOF, or bound expiry — since the readability handler and
/// the timeout fire from different queues.
nonisolated enum ChildProcessReadiness {
    static func waitForData(on pipe: Pipe, bound: TimeInterval = TestBounds.hangGuard) async -> Bool {
        await waitForReadableData(on: pipe.fileHandleForReading, bound: bound)
    }

    static func waitForFIFOReady(at path: String, bound: TimeInterval = TestBounds.hangGuard) async -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return await waitForReadableData(on: handle, bound: bound)
    }

    /// Creates the FIFO node `waitForFIFOReady(at:)` reads from. Must run
    /// before the child is spawned — a shell's `> path` redirection creates
    /// an ordinary file instead of using a FIFO if the node doesn't already
    /// exist as one. `EEXIST` is not an error: callers each use a fresh
    /// path under their own temp directory, but tolerating it keeps this
    /// safe to call more than once for the same path.
    static func makeFIFO(at path: String) {
        if mkfifo(path, 0o600) != 0, errno != EEXIST {
            preconditionFailure("mkfifo(\(path)) failed: errno=\(errno)")
        }
    }

    private static func waitForReadableData(on handle: FileHandle, bound: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            // A cancellable `DispatchWorkItem`, cancelled the instant the
            // readability handler wins the race — otherwise the timer sits
            // held for the full `bound` regardless, and firing afterward
            // would set `readabilityHandler = nil` again, potentially
            // clobbering a handler a *later* wait on the same `FileHandle`
            // had since installed.
            let timeoutWorkItem = DispatchWorkItem {
                handle.readabilityHandler = nil
                once.resume(false)
            }
            once.setOnResumed { timeoutWorkItem.cancel() }
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                fileHandle.readabilityHandler = nil
                once.resume(!data.isEmpty)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound, execute: timeoutWorkItem)
        }
    }
}
