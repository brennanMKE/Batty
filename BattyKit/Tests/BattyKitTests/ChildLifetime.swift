// ChildLifetime.swift

import Foundation

/// Ties a test child's lifetime to the test rather than to a timer: the child
/// blocks reading a stdin pipe the `Process` owns, so it lives until it is
/// killed or that pipe's write end closes (including when the test process dies).
nonisolated enum ChildLifetime {
    /// The tail of a `/bin/sh -c` script. `exec` keeps the child a single pid
    /// and preserves an ignored `SIGTERM` disposition.
    static let holdCommand = "exec /bin/cat > /dev/null"

    /// Must be set on every held child: on an inherited stdin it may read EOF at once.
    static func hold(_ process: Process) {
        process.standardInput = Pipe()
    }
}
