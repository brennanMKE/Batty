// UITestProjectsFileOverrideTests.swift

import Testing
@testable import BattyKit

@MainActor
struct UITestProjectsFileOverrideTests {
    private let path = "/tmp/batty-ui-test-projects/projects.json"

    @Test func honoredWithTheScriptVariable() {
        let env = [UITestDriver.scriptEnvVar: "[]", UITestDriver.projectsFileEnvVar: path]
        #expect(UITestDriver.projectsFileOverride(environment: env)?.path == path)
    }

    @Test func ignoredWithoutTheScriptVariable() {
        #expect(UITestDriver.projectsFileOverride(environment: [UITestDriver.projectsFileEnvVar: path]) == nil)
    }

    @Test func ignoredWhenAbsentOrRelative() {
        #expect(UITestDriver.projectsFileOverride(environment: [UITestDriver.scriptEnvVar: "[]"]) == nil)
        let relative = [UITestDriver.scriptEnvVar: "[]", UITestDriver.projectsFileEnvVar: "projects.json"]
        #expect(UITestDriver.projectsFileOverride(environment: relative) == nil)
    }
}
