// NonProjectDirectoryTests.swift

import Foundation
import Testing
@testable import BattyKit

private let home = "/Users/test"
private let tmp = "/var/folders/ab/cd/T/"

private func excluded(_ path: String) -> Bool {
    NonProjectDirectory.contains(path, home: home, temporaryDirectory: tmp)
}

struct NonProjectDirectoryTests {
    @Test func homeIsNotAProjectDirectory() {
        #expect(excluded("/Users/test"))
    }

    @Test func homeWithTrailingSlashAndLiteralTildeMatch() {
        #expect(excluded("/Users/test/"))
        #expect(excluded("~"))
        #expect(excluded("~/"))
    }

    @Test func rootIsNotAProjectDirectory() {
        #expect(excluded("/"))
    }

    @Test func topLevelSystemDirectoriesAreNotProjectDirectories() {
        for path in ["/Users", "/Volumes", "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/var", "/tmp"] {
            #expect(excluded(path), "\(path)")
        }
    }

    @Test func privateTmpAndVarTmpAreNotProjectDirectories() {
        #expect(excluded("/private/tmp"))
        #expect(excluded("/var/tmp"))
        #expect(excluded("/private/var/tmp"))
    }

    @Test func temporaryDirectoryIsNotAProjectDirectory() {
        #expect(excluded(tmp))
        #expect(excluded("/private/var/folders/ab/cd/T"))
    }

    @Test func subfoldersOfHomeAreProjectDirectories() {
        for path in ["~/Desktop", "/Users/test/Documents", "/Users/test/Downloads", "/Users/test/Developer/Batty", "/tmp/build", "/var/folders/ab/cd/T/x"] {
            #expect(!excluded(path), "\(path)")
        }
    }

    @Test func aDifferentUsersHomeIsNotTheInjectedHome() {
        #expect(!excluded("/Users/other"))
    }

    @Test func relativePathIsAProjectDirectory() {
        #expect(!excluded("src"))
    }
}
