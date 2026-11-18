// MCPToolCatalogTests.swift

import BattyXPCCore
import Foundation
import Testing
@testable import batty

struct MCPToolCatalogTests {
    nonisolated static let flagOn = FeatureFlags(sharedProjectImages: true, agentIntegration: true)
    nonisolated static let flagOff = FeatureFlags(sharedProjectImages: false, agentIntegration: false)

    private func catalog(_ flags: FeatureFlags = flagOn) -> MCPToolCatalog {
        MCPToolCatalog(payload: CapabilitiesCommand.buildPayload(flags: flags))
    }

    private func properties(_ tool: MCPTool) -> [String: MCPJSONValue] {
        if case let .object(fields)? = tool.inputSchema["properties"] { return fields }
        return [:]
    }

    // MARK: - Tool list mirrors capabilities

    @Test(arguments: [false, true])
    func toolsMatchCapabilitiesVerbsMinusExclusions(agentIntegration: Bool) {
        let flags = agentIntegration ? Self.flagOn : Self.flagOff
        let verbs = Set(CapabilitiesCommand.verbs(flags: flags).map(\.name)).subtracting(MCPToolCatalog.excludedVerbPaths)
        let tools = Set(catalog(flags).tools.map(\.name))
        #expect(tools == Set(verbs.map(MCPToolCatalog.toolName(forVerbPath:))))
    }

    @Test func toolPropertiesMatchVerbPropertiesExceptJSON() {
        for tool in catalog().tools {
            let verbProperties = tool.verb.inputSchema.properties.filter { $0.key != "json" }
            let toolProperties = properties(tool)
            #expect(Set(toolProperties.keys) == Set(verbProperties.keys), "\(tool.name)")
            for (key, property) in verbProperties {
                #expect(toolProperties[key]?["type"] == .string(property.type), "\(tool.name).\(key)")
                let expectedEnum = property.enumValues.map { MCPJSONValue.array($0.map(MCPJSONValue.string)) }
                #expect(toolProperties[key]?["enum"] == expectedEnum, "\(tool.name).\(key)")
            }
        }
    }

    @Test func toolNamesAreValidMCPNamesAndUnique() throws {
        let names = catalog().tools.map(\.name)
        #expect(Set(names).count == names.count)
        let pattern = try Regex("^[A-Za-z0-9_.-]{1,64}$")
        for name in names {
            #expect(name.wholeMatch(of: pattern) != nil, "\(name)")
        }
    }

    @Test func toolSchemasCarryNoBattyOnlyKeys() throws {
        let forbidden: Set<String> = ["cliKind", "names", "enumValueNames", "cliRequired", "conflicts"]
        func walk(_ value: MCPJSONValue, path: String) {
            switch value {
            case let .object(fields):
                for (key, child) in fields {
                    #expect(!forbidden.contains(key), "\(path).\(key)")
                    walk(child, path: "\(path).\(key)")
                }
            case let .array(items):
                for item in items { walk(item, path: path) }
            default:
                break
            }
        }
        for tool in catalog().tools {
            walk(tool.inputSchema, path: tool.name)
            guard case let .array(required)? = tool.inputSchema["required"] else {
                Issue.record("\(tool.name) has no required array")
                continue
            }
            for case let .string(key) in required {
                #expect(properties(tool)[key] != nil, "\(tool.name) requires undeclared \(key)")
            }
        }
    }

    @Test func toolSchemaDefaultsAreTypedToTheirPropertyType() {
        var checked = 0
        for tool in catalog().tools {
            for (key, schema) in properties(tool) {
                guard let defaultValue = schema["default"] else { continue }
                checked += 1
                switch (schema["type"], defaultValue) {
                case (.string("boolean")?, .bool), (.string("integer")?, .int), (.string("string")?, .string):
                    break
                default:
                    Issue.record("\(tool.name).\(key): default \(defaultValue) does not match \(String(describing: schema["type"]))")
                }
            }
        }
        #expect(checked > 0)
    }

    @Test func conflictsAreFoldedIntoToolDescription() throws {
        let split = try #require(catalog().tool(named: "pane_split"))
        #expect(split.description.contains("Constraints:"))
        for conflict in split.verb.inputSchema.conflicts {
            #expect(split.description.contains(conflict.description))
        }
        let ping = try #require(catalog().tool(named: "ping"))
        #expect(!ping.description.contains("Constraints:"))
    }

    @Test func annotationsMatchCapabilitiesAnnotations() {
        for tool in catalog().tools {
            #expect(tool.annotations == CapabilitiesCommand.annotations(forVerbPath: tool.verb.name))
        }
    }

    @Test func excludedVerbPathsAllExistInTheFlagOnTree() {
        let verbs = Set(CapabilitiesCommand.verbs(flags: Self.flagOn).map(\.name))
        #expect(MCPToolCatalog.excludedVerbPaths.isSubset(of: verbs))
    }

    @Test func everyVerbHasAtMostOnePositional() {
        for verb in CapabilitiesCommand.verbs(flags: Self.flagOn) {
            let positionals = verb.inputSchema.properties.values.filter { $0.cliKind == .positional }
            #expect(positionals.count <= 1, "\(verb.name)")
        }
    }

    // MARK: - argv

    @Test func paneSplitArgumentsUseLongOptionsAndEnumFlagSpelling() throws {
        let argv = try catalog().arguments(forToolName: "pane_split", callArguments: [
            "direction": .string("vertical"),
            "command": .string("npm test"),
        ])
        #expect(argv.starts(with: ["pane", "split"]))
        #expect(argv.contains("--command=npm test"))
        #expect(argv.contains("--vertical"))
        #expect(!argv.contains("-c"))
    }

    @Test func jsonFlagIsAddedWhenTheVerbHasIt() throws {
        #expect(try catalog().arguments(forToolName: "id", callArguments: [:]) == ["id", "--json"])
        #expect(try catalog().arguments(forToolName: "ping", callArguments: [:]) == ["ping"])
    }

    @Test func jsonFlagIsOmittedWhenAMutuallyExclusiveParameterIsSet() throws {
        #expect(try catalog().arguments(forToolName: "new", callArguments: ["no-wait": .bool(true)]) == ["new", "--no-wait"])
        #expect(try catalog().arguments(forToolName: "new", callArguments: ["no-wait": .bool(false)]) == ["new", "--json"])
    }

    @Test func positionalFollowsDoubleDash() throws {
        #expect(try catalog().arguments(forToolName: "new", callArguments: ["path": .string("/tmp/x")]) == ["new", "--json", "--", "/tmp/x"])
    }

    @Test func optionValueStartingWithDashIsJoinedWithEquals() throws {
        let argv = try catalog().arguments(forToolName: "pane_split", callArguments: ["command": .string("-rf")])
        #expect(argv.contains("--command=-rf"))
    }

    @Test func falseBooleanFlagIsOmitted() throws {
        let argv = try catalog().arguments(forToolName: "pane_split", callArguments: ["unique": .bool(false)])
        #expect(!argv.contains("--unique"))
    }

    @Test func unknownArgumentIsRejected() {
        #expect(throws: MCPArgumentError.unknownArgument("bogus")) {
            try catalog().arguments(forToolName: "id", callArguments: ["bogus": .bool(true)])
        }
        #expect(throws: MCPArgumentError.unknownArgument("json")) {
            try catalog().arguments(forToolName: "id", callArguments: ["json": .bool(true)])
        }
    }

    @Test func wrongJSONTypeIsRejected() {
        #expect(throws: MCPArgumentError.wrongType("pid", expected: "integer")) {
            try catalog().arguments(forToolName: "pane_split", callArguments: ["pid": .string("12")])
        }
    }

    @Test func valueOutsideEnumIsRejected() {
        #expect(throws: MCPArgumentError.self) {
            try catalog().arguments(forToolName: "pane_split", callArguments: ["view": .string("nope")])
        }
    }

    @Test func missingRequiredArgumentIsRejected() {
        #expect(throws: MCPArgumentError.missingRequired("id")) {
            try catalog().arguments(forToolName: "pane_show", callArguments: [:])
        }
    }
}
