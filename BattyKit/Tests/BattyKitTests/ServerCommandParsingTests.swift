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

    @Test func serverPreviewIsAnUnknownSubcommand() {
        #expect(throws: (any Error).self) { try ServerNounCommand.parseAsRoot(["preview", "--port", "8083"]) }
        #expect(!ServerNounCommand.configuration.subcommands.contains { $0.configuration.commandName == "preview" })
    }

    @Test func startRejectsPortOutOfRange() {
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "0", "--", "x"]) }
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "65536", "--", "x"]) }
    }

    @Test func waitTimeoutOutOfRangeIsRejected() {
        for value in ["inf", "nan", "0", "-1", "86401", "1e300"] {
            #expect(throws: (any Error).self, "start \(value)") { try ServerStartCommand.parse(["--port", "8083", "--wait", "--timeout", value, "--", "x"]) }
        }
        #expect(throws: Never.self) { try ServerStartCommand.parse(["--port", "8083", "--wait", "--timeout", "86400", "--", "x"]) }
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

    @Test func shareRequiresPort() {
        #expect(throws: (any Error).self) { try ServerShareCommand.parse([]) }
        #expect(throws: (any Error).self) { try ServerShareCommand.parse(["--port", "0"]) }
        #expect(throws: Never.self) { try ServerShareCommand.parse(["--port", "9000"]) }
    }

    @Test func shareAcceptsNameSplitAndNoProcessView() throws {
        let request = try ServerShareCommand.parse(["--port", "9000", "--name", "web", "--split", "down", "--no-process-view", "--url", "http://localhost:9000/"]).request()
        #expect(request.port == 9000)
        #expect(request.name == "web")
        #expect(request.split == .down)
        #expect(request.processView == false)
        #expect(request.url == "http://localhost:9000/")
        let plain = try ServerShareCommand.parse(["--port", "9000"]).request()
        #expect(plain.processView == nil)
        #expect(plain.name == nil)
        #expect(throws: (any Error).self) { try ServerShareCommand.parse(["--port", "9000", "--wait"]) }
    }

    @Test func attachIsAnUnknownSubcommand() {
        #expect(throws: (any Error).self) { try ServerNounCommand.parseAsRoot(["attach", "--port", "8083"]) }
        #expect(!ServerNounCommand.configuration.subcommands.contains { $0.configuration.commandName == "attach" })
    }

    @Test func startAcceptsNameAndNoProcessView() throws {
        let request = try ServerStartCommand.parse(["--port", "8083", "--name", "api", "--no-process-view", "--", "x"]).request(currentDirectory: "/tmp")
        #expect(request.name == "api")
        #expect(request.processView == false)
        #expect(try ServerStartCommand.parse(["--port", "8083", "--", "x"]).request(currentDirectory: "/tmp").processView == nil)
    }

    @Test func startRejectsStatsUrl() {
        #expect(throws: (any Error).self) { try ServerStartCommand.parse(["--port", "8083", "--stats-url", "http://x/", "--", "x"]) }
    }

    @Test func listAcceptsJson() throws {
        #expect(try ServerListCommand.parse(["--json"]).json)
        #expect(try !ServerListCommand.parse([]).json)
        #expect(throws: (any Error).self) { try ServerListCommand.parse(["--port", "1"]) }
    }

    @Test func listLinesAreTabSeparatedWithTailnetOnlyWhenSet() {
        let a = UUID(), b = UUID()
        let reply = ServerListReply(servers: [
            ServerListItem(serverID: a, name: "go", port: 8083, kind: .terminal, state: .listening, url: "http://127.0.0.1:8083/"),
            ServerListItem(serverID: b, name: "web", port: 9000, kind: .external, state: .starting, url: "http://127.0.0.1:9000/", tailnetURL: "https://h.ts.net/"),
        ])
        #expect(ServerListCommand.lines(reply) == [
            "\(a.uuidString)\tgo\t8083\tterminal\tlistening\thttp://127.0.0.1:8083/",
            "\(b.uuidString)\tweb\t9000\texternal\tstarting\thttp://127.0.0.1:9000/\thttps://h.ts.net/",
        ])
        #expect(ServerListCommand.lines(ServerListReply(servers: [])).isEmpty)
    }

    @Test func unshareAcceptsPortOrID() {
        #expect(throws: Never.self) { try ServerUnshareCommand.parse(["--port", "8083"]) }
        #expect(throws: Never.self) { try ServerUnshareCommand.parse([UUID().uuidString]) }
    }

    @Test func unshareRequiresPortOrID() {
        #expect(throws: (any Error).self) { try ServerUnshareCommand.parse([]) }
        #expect(throws: (any Error).self) { try ServerUnshareCommand.parse(["not-a-uuid"]) }
        #expect(throws: (any Error).self) { try ServerUnshareCommand.parse(["--port", "0"]) }
    }

    @Test func stopAcceptsPortOrPaneID() throws {
        #expect(throws: Never.self) { try ServerStopCommand.parse(["--port", "8083"]) }
        #expect(throws: Never.self) { try ServerStopCommand.parse([UUID().uuidString]) }
        #expect(throws: (any Error).self) { try ServerStopCommand.parse([]) }
        #expect(throws: (any Error).self) { try ServerRestartCommand.parse(["not-a-uuid"]) }
    }

    @Test func tailnetAcceptsPortOrID() throws {
        let byPort = try ServerTailnetCommand.parse(["--port", "3000"])
        #expect(try byPort.request().port == 3000)
        #expect(try byPort.request().off == nil)
        let id = UUID()
        #expect(try ServerTailnetCommand.parse([id.uuidString]).request().serverID == id)
    }

    @Test func tailnetAcceptsOff() throws {
        #expect(try ServerTailnetCommand.parse(["--port", "3000", "--off"]).request().off == true)
    }

    @Test func tailnetRequiresPortOrID() {
        #expect(throws: (any Error).self) { try ServerTailnetCommand.parse([]) }
        #expect(throws: (any Error).self) { try ServerTailnetCommand.parse(["--port", "0"]) }
    }

    @Test func shareAcceptsTailnet() throws {
        #expect(try ServerShareCommand.parse(["--port", "3000", "--tailnet"]).request().tailnet == true)
        #expect(try ServerShareCommand.parse(["--port", "3000"]).request().tailnet == nil)
    }
}
