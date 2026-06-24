// SessionURLBuilderTests.swift

import Foundation
import Testing
@testable import BattyKit

struct SessionURLBuilderTests {

    // MARK: - Path resolution

    @Test func resolvesDotToCurrentDirectory() {
        // Use /usr as an explicit known directory to avoid xctest runner's /tmp CWD.
        let knownDir = URL(filePath: "/usr").standardizedFileURL.path(percentEncoded: false)
        let result = SessionURLBuilder.resolve(path: ".", currentDirectory: knownDir)
        #expect(result == knownDir)
    }

    @Test func resolvesAbsoluteDirectoryPath() {
        // Use a stable system directory that is always present.
        let expected = URL(filePath: "/usr/bin").standardizedFileURL.path(percentEncoded: false)
        let result = SessionURLBuilder.resolve(path: "/usr/bin", currentDirectory: "/")
        #expect(result == expected)
    }

    @Test func resolvesRelativePathAgainstCurrentDirectory() {
        // Resolve "bin" relative to "/usr" — always exists on macOS.
        let expected = URL(filePath: "/usr/bin").standardizedFileURL.path(percentEncoded: false)
        let result = SessionURLBuilder.resolve(path: "bin", currentDirectory: "/usr")
        #expect(result == expected)
    }

    @Test func returnsNilForNonexistentPath() {
        let result = SessionURLBuilder.resolve(path: "/nonexistent/path/xyz", currentDirectory: "/")
        #expect(result == nil)
    }

    @Test func returnsNilForFilePath() {
        let result = SessionURLBuilder.resolve(path: "/etc/hosts", currentDirectory: "/")
        #expect(result == nil)
    }

    @Test func expandsTildeInPath() {
        var home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path(percentEncoded: false)
        if home.hasSuffix("/"), home != "/" { home = String(home.dropLast()) }
        let result = SessionURLBuilder.resolve(path: "~", currentDirectory: "/")
        #expect(result == home)
    }

    // MARK: - URL building

    @Test func buildURLProducesCorrectSchemeAndHost() {
        let url = SessionURLBuilder.buildURL(absolutePath: "/Users/test/Developer")
        #expect(url?.scheme == "batty")
        #expect(url?.host() == "session")
    }

    @Test func buildURLEncodesPathInQueryItem() {
        let path = "/Users/test/Developer/My Project"
        let url = SessionURLBuilder.buildURL(absolutePath: path)
        guard let url else {
            Issue.record("buildURL returned nil")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryPath = components?.queryItems?.first(where: { $0.name == "path" })?.value
        #expect(queryPath == path)
    }

    // MARK: - URL parsing

    @Test func sessionPathRoundTrips() {
        let original = "/Users/test/Developer/Batty"
        guard let url = SessionURLBuilder.buildURL(absolutePath: original) else {
            Issue.record("buildURL returned nil")
            return
        }
        let parsed = SessionURLBuilder.sessionPath(from: url)
        #expect(parsed == original)
    }

    @Test func sessionPathReturnsNilForWrongScheme() {
        let url = URL(string: "https://example.com/session?path=/tmp")!
        #expect(SessionURLBuilder.sessionPath(from: url) == nil)
    }

    @Test func sessionPathReturnsNilForWrongHost() {
        let url = URL(string: "batty://window?path=/tmp")!
        #expect(SessionURLBuilder.sessionPath(from: url) == nil)
    }

    @Test func sessionPathRoundTripsPathWithSpaces() {
        let original = "/Users/test/My Projects/Cool App"
        guard let url = SessionURLBuilder.buildURL(absolutePath: original) else {
            Issue.record("buildURL returned nil")
            return
        }
        let parsed = SessionURLBuilder.sessionPath(from: url)
        #expect(parsed == original)
    }
}
