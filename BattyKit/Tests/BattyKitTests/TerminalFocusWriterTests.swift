// TerminalFocusWriterTests.swift

import Foundation
import Testing

/// Model-initiated terminal focus has one writer: `WindowRuntime`. A view
/// that called `focusWhenReady` from `onAppear`/`onChange` would infer focus
/// intent from an observed flip in every mounted Session.
struct TerminalFocusWriterTests {

    private static func sourcesURL() -> URL {
        // #filePath: .../BattyKit/Tests/BattyKitTests/TerminalFocusWriterTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // -> BattyKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> BattyKit/
            .appending(path: "Sources/BattyKit", directoryHint: .isDirectory)
    }

    @Test func onlyWindowRuntimeRequestsTerminalFocus() throws {
        let root = Self.sourcesURL()
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var callers: Set<String> = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("focusWhenReady(") {
                callers.insert(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        #expect(scanned > 0)
        #expect(callers == ["Commands/TerminalSurfaceFocuser.swift", "Runtime/WindowRuntime.swift"])
    }
}
