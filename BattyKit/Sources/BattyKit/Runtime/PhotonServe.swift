// PhotonServe.swift

import BattyXPCCore
import Darwin
import Foundation

/// Finds PhotonHTTP's `photon` executable (#0693). Never runs a shell: the
/// caller's `PATH`, then the installer's locations.
public nonisolated enum PhotonExecutableLocator {
    public static func candidates(searchPath: String?, home: String) -> [String] {
        let fromPath = (searchPath ?? "").split(separator: ":").filter { !$0.isEmpty }.map { "\($0)/photon" }
        let fallbacks = ["/usr/local/bin/photon", "\(home)/.local/bin/photon", "/opt/homebrew/bin/photon"]
        var seen = Set<String>()
        return (fromPath + fallbacks).filter { seen.insert($0).inserted }
    }

    public static func locate(
        searchPath: String?,
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = isExecutableRegularFile
    ) -> URL? {
        candidates(searchPath: searchPath, home: home).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    public static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

/// The only command line Batty runs `photon` with.
public enum PhotonServeCommand {
    public static func arguments(photon: URL, root: String, port: UInt16) -> [String] {
        [photon.path, "serve", root, "--host", "127.0.0.1", "--port", "\(port)"]
    }

    /// The line typed into the terminal Pane.
    public static func commandLine(photon: URL, root: String, port: UInt16) -> String {
        arguments(photon: photon, root: root, port: port).map(ShellQuote.posix).joined(separator: " ")
    }
}

public nonisolated enum PhotonInstall {
    public static let command = "curl -fsSL https://photon-http.sstools.co/install.sh | bash"
    public static let gettingStartedURL = URL(string: "https://photon-http.sstools.co/docs/getting-started.md")!
    /// The Docs page quotes this text; keep the two identical.
    public static let notInstalledMessage = "`photon` (PhotonHTTP) isn't installed. Install it from Settings, or run `curl -fsSL https://photon-http.sstools.co/install.sh | bash` (macOS 15+, Swift 6.4 toolchain), then check with `photon --help`. See https://photon-http.sstools.co/docs/getting-started.md"
}

extension StopBounds {
    /// PhotonHTTP drains for up to 10 s after the first signal, and a second
    /// signal doesn't shorten the drain.
    public nonisolated static let photonServe = StopBounds(interrupt: .seconds(11), terminate: .seconds(2))
}

/// A free TCP port on 127.0.0.1, found by binding port 0 and closing the
/// socket. Another process may take it before `photon` binds; photon then
/// exits 1 and the entry shows Crashed.
public nonisolated enum LoopbackPortPicker {
    public static func pick() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: address.sin_port)
        return port == 0 ? nil : port
    }
}

/// UI tests never look for the real `photon`. Under UI-test mode,
/// `BATTY_UI_TEST_FAKE_PHOTON=present` serves a stub that never listens;
/// unset or `absent` means not installed.
public enum PhotonUITestFake {
    public static let environmentVar = "BATTY_UI_TEST_FAKE_PHOTON"

    /// Nil outside UI-test mode; otherwise the fake's answer.
    static func override(environment: [String: String]) -> URL?? {
        guard environment[QuitConfirmation.testModeEnvVar] == "1" else { return nil }
        guard environment[environmentVar] == "present" else { return .some(nil) }
        return .some(writeStub())
    }

    private static func writeStub() -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("batty-uitest-photon", isDirectory: true)
        let stub = directory.appendingPathComponent("photon")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "#!/bin/sh\nexec sleep 3600\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        } catch {
            return nil
        }
        return stub
    }
}
