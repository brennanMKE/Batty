// ProjectNameResolverTests.swift

import Foundation
import Testing
@testable import BattyKit

struct ProjectNameResolverTests {
    private static let fixturesURL: URL = {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()  // BattyTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("BattyKit/Tests/BattyKitTests/Fixtures")
    }()

    private static let resolver = ProjectNameResolver.Resolver(rules: ProjectNameRules.bundled)

    private static func fixtureDir(_ name: String) -> String {
        fixturesURL.appendingPathComponent("projects/\(name)").path
    }

    @Test func nodeFixtureResolvesPackageName() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("node")) == "test-node-project")
    }

    @Test func rustFixtureResolvesCargoName() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("rust")) == "test-rust-project")
    }

    @Test func swiftSPMFixtureResolvesPackageName() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("swift-spm")) == "TestSwiftPkg")
    }

    @Test func swiftXcodeFixtureResolvesBasename() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("swift-xcode")) == "MyApp")
    }

    @Test func goFixtureResolvesLastModulePathSegment() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("go")) == "test-go-project")
    }

    @Test func pythonFixtureResolvesProjectName() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("python")) == "test-python-project")
    }

    @Test func noManifestReturnsNil() {
        #expect(Self.resolver.resolve(at: Self.fixtureDir("no-manifest")) == nil)
    }

    @Test func missingDirectoryReturnsNilWithoutCrashing() {
        #expect(Self.resolver.resolve(at: "/path/that/does/not/exist") == nil)
    }

    @Test func emptyPathReturnsNil() {
        #expect(Self.resolver.resolve(at: "") == nil)
    }

    @Test func bundledRulesLoadFromResource() {
        let rules = ProjectNameRules.bundled
        #expect(!rules.rules.isEmpty)
        #expect(!rules.priority.isEmpty)
        let ids = Set(rules.rules.map(\.id))
        #expect(ids.contains("swift-spm"))
        #expect(ids.contains("rust"))
        #expect(ids.contains("node"))
    }
}
