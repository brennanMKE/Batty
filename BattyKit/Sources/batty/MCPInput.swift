// MCPInput.swift

import Foundation
import os

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "MCPInput")

/// Reads a handle through its own readability source. `FileHandle.bytes`
/// shares one process-wide serial reader, so one idle handle starves every
/// other `bytes` iterator in the process.
nonisolated enum MCPInput {
    static let chunkSize = 64 * 1024

    /// Finishes at end of file or on a read error. Never closes `handle`.
    static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let fd = handle.fileDescriptor
        var info = stat()
        if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            // A dispatch read source never fires at end of a regular file, so
            // `readabilityHandler` would hang there. Regular-file reads never
            // block on a writer, so a plain loop is safe.
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
                    if count > 0 {
                        if case .terminated = continuation.yield(Data(buffer[0..<count])) { return }
                        continue
                    }
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 { logger.error("mcp input read failed: errno \(errno, privacy: .public)") }
                    continuation.finish()
                    return
                }
            }
            return stream
        }
        handle.readabilityHandler = { fileHandle in
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            var count: Int
            repeat {
                count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkSize) }
            } while count < 0 && errno == EINTR
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count == 0 {
                fileHandle.readabilityHandler = nil
                continuation.finish()
            } else if errno != EAGAIN {
                logger.error("mcp input read failed: errno \(errno, privacy: .public)")
                fileHandle.readabilityHandler = nil
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
        return stream
    }
}
