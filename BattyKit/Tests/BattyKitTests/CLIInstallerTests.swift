// CLIInstallerTests.swift

import Foundation
import Testing
@testable import BattyKit

/// Tests for the #0268 rework of `CLIInstaller`: a four-state install
/// inspection (replacing a bare `isInstalled() -> Bool`) and `isBundleDurable`
/// (refusing to install from a DerivedData/Build products bundle).
///
/// All state is staged under a private temporary directory tree — no
/// `/usr/local/bin`, no real app bundle, no authorization dialog.
struct CLIInstallerTests {

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "CLIInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBundle(in root: URL, appName: String = "Batty.app") -> (bundleURL: URL, cliPath: String) {
        let bundleURL = root.appending(path: appName, directoryHint: .isDirectory)
        let binDir = bundleURL.appending(path: "Contents/Resources/bin", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let cliURL = binDir.appending(path: "batty", directoryHint: .notDirectory)
        try? Data("fake binary".utf8).write(to: cliURL)
        return (bundleURL, cliURL.path(percentEncoded: false))
    }

    // MARK: - Four-state inspection

    @Test func inspectReturnsNotInstalledWhenNothingAtDestination() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        let installer = CLIInstaller(installPath: installPath, bundleURL: root, fileManager: .default)

        #expect(installer.inspectInstallState() == .notInstalled)
    }

    @Test func inspectReturnsInstalledHereForAMatchingSymlink() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, cliPath) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: cliPath)

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(installer.inspectInstallState() == .installedHere)
    }

    @Test func inspectReturnsInstalledElsewhereAndSurfacesTheStaleTargetForADanglingOrForeignLink() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, _) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        let staleTarget = root.appending(path: "OldBatty.app/Contents/Resources/bin/batty", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: staleTarget)

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(installer.inspectInstallState() == .installedElsewhere(staleTarget))
    }

    @Test func inspectReturnsBlockedByFileForARegularFileAtTheDestination() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, _) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        try Data("a real file the user put here".utf8).write(to: URL(filePath: installPath))

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(installer.inspectInstallState() == .blockedByFile)
    }

    // MARK: - isBundleDurable

    @Test func isBundleDurableRefusesADerivedDataBundle() {
        let path = "/Users/jane/Library/Developer/Xcode/DerivedData/Batty-abc123/Build/Products/Debug/Batty.app"
        let installer = CLIInstaller(bundleURL: URL(filePath: path))

        #expect(installer.isBundleDurable == false)
    }

    @Test func isBundleDurableRefusesABuildProductsBundleOutsideDerivedData() {
        let path = "/Users/jane/dev/Batty/Build/Products/Release/Batty.app"
        let installer = CLIInstaller(bundleURL: URL(filePath: path))

        #expect(installer.isBundleDurable == false)
    }

    @Test func isBundleDurableAcceptsAnApplicationsBundle() {
        let installer = CLIInstaller(bundleURL: URL(filePath: "/Applications/Batty.app"))

        #expect(installer.isBundleDurable == true)
    }

    // MARK: - install() safety: never clobber, never install from a build directory

    @Test func installThrowsBlockedByFileAndLeavesTheRealFileUntouched() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, _) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        let originalContents = Data("a real file the user put here".utf8)
        try originalContents.write(to: URL(filePath: installPath))

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(throws: CLIInstallerError.blockedByFile(installPath)) {
            try installer.install()
        }
        // The privileged rm -f/ln -s must never have run: the file survives untouched.
        let survived = try Data(contentsOf: URL(filePath: installPath))
        #expect(survived == originalContents)
    }

    @Test func installThrowsBundleNotDurableAndCreatesNothingAtTheDestination() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let derivedDataRoot = root.appending(path: "DerivedData/Batty-abc/Build/Products/Debug", directoryHint: .isDirectory)
        let (bundleURL, _) = makeBundle(in: derivedDataRoot)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(throws: CLIInstallerError.bundleNotDurable(bundleURL.path(percentEncoded: false))) {
            try installer.install()
        }
        #expect(FileManager.default.fileExists(atPath: installPath) == false)
    }

    // MARK: - uninstall() safety

    @Test func uninstallThrowsBlockedByFileAndLeavesTheRealFileUntouched() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, _) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        let originalContents = Data("a real file the user put here".utf8)
        try originalContents.write(to: URL(filePath: installPath))

        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        #expect(throws: CLIInstallerError.blockedByFile(installPath)) {
            try installer.uninstall()
        }
        let survived = try Data(contentsOf: URL(filePath: installPath))
        #expect(survived == originalContents)
    }

    @Test func uninstallIsANoOpWhenNothingIsInstalled() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundleURL, _) = makeBundle(in: root)
        let installPath = root.appending(path: "batty", directoryHint: .notDirectory).path(percentEncoded: false)
        let installer = CLIInstaller(installPath: installPath, bundleURL: bundleURL, fileManager: .default)

        try installer.uninstall()

        #expect(FileManager.default.fileExists(atPath: installPath) == false)
    }
}
