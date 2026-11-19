// ServerCommandParsingTests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct ServerCommandParsingTests {
    @Test func startRequiresPortAndCommand() {
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--", "go", "run", "."]) }
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "8083"]) }
        #expect(throws: Never.self) { try ServerStartCommand.parse(["--port", "8083", "--", "go", "run", "."]) }
    }

    @Test func startRejectsPortOutOfRange() {
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "0", "--", "x"]) }
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "65536", "--", "x"]) }
    }

    @Test func singleTrailingArgumentIsUsedVerbatim() throws {
        let command = try ServerStartCommand.parse(["--port", "8083", "--", "go run . | tee log"])
        #expect(try command.request(currentDirectory: "/tmp").command == "go run . | tee log")
    }

    @Test func multipleTrailingArgumentsAreQuotedAndJoined() throws {
        let command = try ServerStartCommand.parse(["--port", "8083", "--", "python3", "-m", "http.server", "--directory", "my site"])
        #expect(try command.request(currentDirectory: "/tmp").command == "python3 -m http.server --directory 'my site'")
    }

    @Test func workingDirectoryIsTheAbsoluteCurrentDirectory() throws {
        let command = try ServerStartCommand.parse(["--port", "8083", "--", "x"])
        #expect(try command.request(currentDirectory: "/tmp/site/../web").workingDirectory == "/tmp/web")
    }

    @Test func splitAcceptsRightAndDownOnly() throws {
        #expect(try ServerStartCommand.parse(["--port", "1", "--split", "right", "--", "x"]).split == .right)
        #expect(try ServerStartCommand.parse(["--port", "1", "--split", "down", "--", "x"]).split == .down)
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "1", "--split", "left", "--", "x"]) }
    }

    @Test func attachAcceptsCommandAndCwd() throws {
        let command = try ServerAttachCommand.parse(["--port", "9000", "--command", "npm start", "--cwd", "web"])
        let request = try command.request(currentDirectory: "/tmp/project")
        #expect(request.command == "npm start")
        #expect(request.workingDirectory == "/tmp/project/web")
        #expect(try ServerAttachCommand.parse(["--port", "9000"]).request(currentDirectory: "/tmp").workingDirectory == nil)
    }

    @Test func stopAcceptsPortOrPaneID() throws {
        #expect(throws: Never.self) { try ServerStopCommand.parse(["--port", "8083"]) }
        #expect(throws: Never.self) { try ServerStopCommand.parse([UUID().uuidString]) }
        #expect(throws: (any Error).self) { try ServerStopCommand.parse([]) }
        #expect(throws: (any Error).self) { try ServerRestartCommand.parse(["not-a-uuid"]) }
    }
}
