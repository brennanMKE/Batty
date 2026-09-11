// main.swift

import BattyKit
import Foundation
import SwiftUI

// #0364: refuse to act as the `batty` CLI when reached under that name
// instead of the real, LaunchServices-resolved bundle path. Must run here,
// as literal top-level code before any SwiftUI/AppKit type is touched —
// see `BattyApp.swift`'s comment on why `@main` moved out of `BattyApp`.
ArgvZeroGuard.enforce(
    argv0: CommandLine.arguments.first,
    executableName: Bundle.main.infoDictionary?["CFBundleExecutable"] as? String,
    write: { FileHandle.standardError.write(Data($0.utf8)) },
    terminate: { exit($0) }
)

BattyApp.main()
