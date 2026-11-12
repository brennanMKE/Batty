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
}
