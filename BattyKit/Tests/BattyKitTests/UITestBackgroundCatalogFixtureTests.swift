// UITestBackgroundCatalogFixtureTests.swift

import Foundation
import Testing
@testable import BattyKit

@MainActor
struct UITestBackgroundCatalogFixtureTests {
    @Test func backgroundCatalogFixtureDirectoryNeedsTheScriptVariable() {
        let path = "/tmp/batty-catalog-fixture"
        #expect(UITestDriver.backgroundCatalogFixtureDirectory(environment: [UITestDriver.backgroundCatalogDirEnvVar: path]) == nil)
        let env = [UITestDriver.scriptEnvVar: "[]", UITestDriver.backgroundCatalogDirEnvVar: path]
        #expect(UITestDriver.backgroundCatalogFixtureDirectory(environment: env)?.path == path)
    }

    @Test func backgroundCatalogFixtureDirectoryIgnoresARelativePath() {
        let env = [UITestDriver.scriptEnvVar: "[]", UITestDriver.backgroundCatalogDirEnvVar: "relative/fixture"]
        #expect(UITestDriver.backgroundCatalogFixtureDirectory(environment: env) == nil)
    }

    @Test func aFixtureLaunchClearsTheBackgroundPreferencesAndOnlyThen() throws {
        let test = TestDefaults()
        defer { test.tearDown() }
        let defaults = test.defaults
        let appWide = FileManager.default.temporaryDirectory.appendingPathComponent("batty-appwide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appWide) }
        let picked = appWide.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        func seed() {
            defaults.set(["https://catalogs.example.com/catalog.json"], forKey: SettingsPreference.backgroundCatalogURLsKey)
            defaults.set(true, forKey: SettingsPreference.backgroundCatalogsBrowsedKey)
            defaults.set(false, forKey: SettingsPreference.backgroundCatalogsAutoCheckKey)
            defaults.set("/tmp/picked.png", forKey: SettingsPreference.backgroundImagePathKey)
        }
        let keys = [
            SettingsPreference.backgroundCatalogURLsKey,
            SettingsPreference.backgroundCatalogsBrowsedKey,
            SettingsPreference.backgroundCatalogsAutoCheckKey,
            SettingsPreference.backgroundImagePathKey,
        ]
        seed()
        UITestDriver.resetBackgroundPreferencesForFixture(defaults: defaults, appWideDirectory: appWide, environment: [UITestDriver.scriptEnvVar: "[]"])
        #expect(keys.allSatisfy { defaults.object(forKey: $0) != nil })
        #expect(FileManager.default.fileExists(atPath: picked.path))

        let env = [UITestDriver.scriptEnvVar: "[]", UITestDriver.backgroundCatalogDirEnvVar: "/tmp/batty-catalog-fixture"]
        UITestDriver.resetBackgroundPreferencesForFixture(defaults: defaults, appWideDirectory: appWide, environment: env)
        #expect(keys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(!FileManager.default.fileExists(atPath: picked.path))
    }

    @Test func otherHostsAreServedFromTheHostsFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batty-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("hosts/catalogs.example.com/sets/catalog.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: file)
        let fetcher = FixtureBackgroundCatalogFetcher(directory: folder)
        let request = HostedFetchRequest(url: URL(string: "https://catalogs.example.com/sets/catalog.json")!, byteLimit: 100, timeout: 1)
        let response = try await fetcher.fetch(request, progress: nil)
        #expect(response.body == Data("{}".utf8))
        do {
            _ = try await fetcher.fetch(HostedFetchRequest(url: URL(string: "https://catalogs.example.com/missing.json")!, byteLimit: 100, timeout: 1), progress: nil)
            Issue.record("expected not found")
        } catch {
            #expect(error == .notFound)
        }
    }

    @Test func anUnknownHostIsUnreachable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batty-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fetcher = FixtureBackgroundCatalogFetcher(directory: folder)
        do {
            _ = try await fetcher.fetch(HostedFetchRequest(url: URL(string: "https://nowhere.example.com/catalog.json")!, byteLimit: 100, timeout: 1), progress: nil)
            Issue.record("expected unreachable")
        } catch {
            #expect(error == .unreachable)
        }
    }
}
