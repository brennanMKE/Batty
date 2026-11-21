// PhotonServeTests.swift

import Foundation
import Testing
@testable import BattyKit

struct PhotonExecutableLocatorTests {
    private func locate(_ executables: Set<String>, path: String? = "/a/bin:/b/bin") -> String? {
        PhotonExecutableLocator.locate(searchPath: path, home: "/fake/home", isExecutable: { executables.contains($0) })?.path
    }

    @Test func findsPhotonOnSearchPathFirst() {
        #expect(locate(["/b/bin/photon", "/usr/local/bin/photon"]) == "/b/bin/photon")
    }

    @Test func fallsBackToUsrLocalBin() {
        #expect(locate(["/usr/local/bin/photon", "/fake/home/.local/bin/photon"]) == "/usr/local/bin/photon")
    }

    @Test func fallsBackToHomeDotLocalBin() {
        #expect(locate(["/fake/home/.local/bin/photon", "/opt/homebrew/bin/photon"]) == "/fake/home/.local/bin/photon")
    }

    @Test func checksOptHomebrewLast() {
        #expect(locate(["/opt/homebrew/bin/photon"]) == "/opt/homebrew/bin/photon")
        #expect(PhotonExecutableLocator.candidates(searchPath: nil, home: "/fake/home").last == "/opt/homebrew/bin/photon")
    }

    @Test func reportsAbsentWhenNoCandidateIsExecutable() {
        #expect(locate([]) == nil)
        #expect(locate([], path: nil) == nil)
    }

    @Test func ignoresEmptyPathEntriesAndDuplicates() {
        let candidates = PhotonExecutableLocator.candidates(searchPath: ":/usr/local/bin::/a:/a", home: "/fake/home")
        #expect(candidates == ["/usr/local/bin/photon", "/a/photon", "/fake/home/.local/bin/photon", "/opt/homebrew/bin/photon"])
    }

    @Test func acceptsOnlyAnExecutableNamedPhoton() {
        #expect(locate(["/a/bin/SwiftWebServer"]) == nil)
    }
}

@MainActor
struct PhotonServeCommandTests {
    @Test func argumentsAreExactlyServeRootHostAndPort() {
        let args = PhotonServeCommand.arguments(photon: URL(fileURLWithPath: "/usr/local/bin/photon"), root: "/Users/x/site", port: 52144)
        #expect(args == ["/usr/local/bin/photon", "serve", "/Users/x/site", "--host", "127.0.0.1", "--port", "52144"])
    }

    @Test func commandLineQuotesPathsWithSpacesAndQuotes() {
        let line = PhotonServeCommand.commandLine(photon: URL(fileURLWithPath: "/opt/my tools/photon"), root: "/tmp/it's here", port: 8080)
        #expect(line == "'/opt/my tools/photon' 'serve' '/tmp/it'\\''s here' '--host' '127.0.0.1' '--port' '8080'")
    }
}

struct PhotonInstallTests {
    @Test func installCommandIsTheDocumentedDefault() {
        #expect(PhotonInstall.command == "curl -fsSL https://photon-http.sstools.co/install.sh | bash")
    }

    @Test func notInstalledMessageNamesTheInstallCommandAndGettingStarted() {
        #expect(PhotonInstall.notInstalledMessage.contains(PhotonInstall.command))
        #expect(PhotonInstall.notInstalledMessage.contains(PhotonInstall.gettingStartedURL.absoluteString))
        #expect(PhotonInstall.notInstalledMessage.contains("isn't installed"))
    }
}

struct LoopbackPortPickerTests {
    @Test nonisolated func pickReturnsANonZeroPortThatCanBeBound() throws {
        let port = try #require(LoopbackPortPicker.pick())
        #expect(port > 0)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
    }
}

struct StopBoundsPhotonTests {
    @Test func photonInterruptBoundExceedsTheTenSecondDrain() {
        #expect(StopBounds.photonServe.interrupt > .seconds(10))
    }
}
