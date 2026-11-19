// TabNewCommandTests.swift

import Foundation
import Testing
@testable import batty

struct TabNewCommandTests {

    private nonisolated func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TabNewCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test nonisolated func relativeCwdResolvesAgainstTheCurrentDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let result = TabNewCommand.resolveWorkingDirectory("./sub/../sub", currentDirectory: root.path)

        #expect(result == .success(root.appendingPathComponent("sub").path))
    }

    @Test nonisolated func cwdThatDoesNotExistIsRejected() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing").path

        #expect(TabNewCommand.resolveWorkingDirectory(missing, currentDirectory: "/") == .failure(.notADirectory(missing)))
    }

    @Test nonisolated func cwdThatIsAFileIsRejected() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        #expect(TabNewCommand.resolveWorkingDirectory(file.path, currentDirectory: "/") == .failure(.notADirectory(file.path)))
    }
}
