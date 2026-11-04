// ProjectFileReadGate.swift

import Foundation

/// A `ProjectStore` file read that fails on demand, for read failures a test
/// can't safely force for real, such as a full file descriptor table.
@MainActor
final class ProjectFileReadGate {
    var failure: Error?
    private(set) var reads = 0

    func read(_ url: URL) throws -> Data {
        reads += 1
        if let failure { throw failure }
        return try Data(contentsOf: url)
    }

    /// A Cocoa read error other than no-such-file, which the store treats as a
    /// failed read.
    static func cocoaReadError(posix: POSIXErrorCode) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(posix)])
    }
}
