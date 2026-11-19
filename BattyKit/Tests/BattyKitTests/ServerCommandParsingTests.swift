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

    @Test func serveDirDefaultsToTheCurrentDirectory() throws {
        let command = try ServerServeCommand.parse([])
        #expect(try command.request(currentDirectory: "/tmp/site").root == "/tmp/site")
    }

    @Test func serveDirIsMadeAbsolute() throws {
        #expect(try ServerServeCommand.parse(["../web"]).request(currentDirectory: "/tmp/site").root == "/tmp/web")
        #expect(try ServerServeCommand.parse(["/abs/dir"]).request(currentDirectory: "/tmp").root == "/abs/dir")
    }

    @Test func servePortOutOfRangeIsRejected() {
        #expect(throws: (any Error).self) { try ServerServeCommand.parse(["--port", "0"]) }
        #expect(throws: (any Error).self) { try ServerServeCommand.parse(["--port", "65536"]) }
        #expect(throws: Never.self) { try ServerServeCommand.parse(["--port", "8000"]) }
    }

    @Test func serveAcceptsOpenAndNoInject() throws {
        let request = try ServerServeCommand.parse(["site", "--open", "--no-inject", "--split", "down"]).request(currentDirectory: "/tmp")
        #expect(request.open == true)
        #expect(request.inject == false)
        #expect(request.split == .down)
        let plain = try ServerServeCommand.parse([]).request(currentDirectory: "/tmp")
        #expect(plain.open == nil)
        #expect(plain.inject == nil)
    }

    @Test func previewRequiresURLOrPort() {
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse([]) }
    }

    @Test func previewRejectsBothURLAndPort() {
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse(["--url", "http://127.0.0.1:1/", "--port", "1"]) }
    }

    @Test func previewRejectsANonLoopbackURL() {
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse(["--url", "https://example.com/"]) }
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse(["--url", "http://127.0.0.1.evil.com/"]) }
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse(["--url", "file:///etc/passwd"]) }
        #expect(throws: Never.self) { try ServerPreviewCommand.parse(["--url", "http://localhost:3000/app"]) }
    }

    @Test func previewPortBuildsA127URL() throws {
        #expect(try ServerPreviewCommand.parse(["--port", "8083"]).targetURL() == "http://127.0.0.1:8083/")
        #expect(throws: (any Error).self) { try ServerPreviewCommand.parse(["--port", "0"]) }
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
