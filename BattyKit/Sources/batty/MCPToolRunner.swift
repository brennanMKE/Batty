// MCPToolRunner.swift

import Foundation
import os

nonisolated struct MCPToolRunResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

nonisolated protocol MCPToolRunner: Sendable {
    func run(_ arguments: [String]) async -> MCPToolRunResult
}

/// Runs a verb by re-executing the `batty` binary, so a tool call gets the
/// verb's own validation, XPC, exit codes and output with no second code path.
/// The child inherits the server's environment (the Pane's `BATTY_*`) and cwd.
nonisolated struct SubprocessToolRunner: MCPToolRunner {
    let executableURL: URL
    var environment: [String: String]?
    /// Test seam: called once the child has launched.
    var onLaunch: (@Sendable () -> Void)?

    init(executableURL: URL, environment: [String: String]? = nil, onLaunch: (@Sendable () -> Void)? = nil) {
        self.executableURL = executableURL
        self.environment = environment
        self.onLaunch = onLaunch
    }

    private struct State {
        var launched = false
        var cancelled = false
    }

    private final class Collected: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var stdout = Data()
        private var stderr = Data()
        func set(stdout data: Data) { lock.withLock { stdout = data } }
        func set(stderr data: Data) { lock.withLock { stderr = data } }
        func read() -> (Data, Data) { lock.withLock { (stdout, stderr) } }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    func run(_ arguments: [String]) async -> MCPToolRunResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let state = OSAllocatedUnfairLock(initialState: State())
        let onLaunch = onLaunch

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPToolRunResult, Never>) in
                let collected = Collected()
                let drained = DispatchGroup()
                drained.enter()
                drained.enter()
                // Both pipes drain concurrently, or a child filling one blocks forever.
                DispatchQueue.global().async {
                    collected.set(stdout: outPipe.fileHandleForReading.readDataToEndOfFile())
                    drained.leave()
                }
                DispatchQueue.global().async {
                    collected.set(stderr: errPipe.fileHandleForReading.readDataToEndOfFile())
                    drained.leave()
                }
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    drained.notify(queue: .global()) {
                        let (out, err) = collected.read()
                        continuation.resume(returning: MCPToolRunResult(
                            exitCode: status,
                            stdout: String(decoding: out, as: UTF8.self),
                            stderr: String(decoding: err, as: UTF8.self)
                        ))
                    }
                }
                let launchError: Error? = state.withLock { state in
                    guard !state.cancelled else { return CancellationError() }
                    do {
                        try box.process.run()
                        state.launched = true
                        return nil
                    } catch {
                        return error
                    }
                }
                if let launchError {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    drained.notify(queue: .global()) {
                        continuation.resume(returning: MCPToolRunResult(exitCode: 127, stdout: "", stderr: "batty: could not run \(executableURL.path): \(launchError)"))
                    }
                    return
                }
                onLaunch?()
            }
        } onCancel: {
            state.withLock { state in
                state.cancelled = true
                if state.launched { box.process.terminate() }
            }
        }
    }
}
