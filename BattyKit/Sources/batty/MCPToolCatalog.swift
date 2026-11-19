// MCPToolCatalog.swift

import BattyXPCCore
import Foundation

nonisolated struct MCPTool: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: MCPJSONValue
    let annotations: CapabilitiesAnnotationsPayload
    let verb: CapabilitiesVerbPayload

    var listEntry: MCPJSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(annotations.readOnlyHint),
                "destructiveHint": .bool(annotations.destructiveHint),
                "idempotentHint": .bool(annotations.idempotentHint),
                "openWorldHint": .bool(annotations.openWorldHint),
            ]),
        ])
    }
}

nonisolated enum MCPArgumentError: Error, Equatable, CustomStringConvertible {
    case unknownArgument(String)
    case wrongType(String, expected: String)
    case notInEnum(String, allowed: [String])
    case belowMinimum(String, minimum: Int)
    case aboveMaximum(String, maximum: Int)
    case missingRequired(String)

    var description: String {
        switch self {
        case let .unknownArgument(name): "unknown argument \"\(name)\""
        case let .wrongType(name, expected): "argument \"\(name)\" must be a \(expected)"
        case let .notInEnum(name, allowed): "argument \"\(name)\" must be one of: \(allowed.joined(separator: ", "))"
        case let .belowMinimum(name, minimum): "argument \"\(name)\" must be at least \(minimum)"
        case let .aboveMaximum(name, maximum): "argument \"\(name)\" must be at most \(maximum)"
        case let .missingRequired(name): "missing required argument \"\(name)\""
        }
    }
}

/// The MCP view of `batty capabilities`: one tool per verb, built from the
/// same payload so the two can't drift. Pure; running a tool is the runner's job.
nonisolated struct MCPToolCatalog: Sendable {
    static let excludedVerbPaths: Set<String> = ["mcp", "agent install", "agent context"]

    /// Never a tool parameter: every call asks for JSON when the verb has it.
    static let jsonProperty = "json"

    let payload: CapabilitiesPayload
    let tools: [MCPTool]

    init(payload: CapabilitiesPayload) {
        self.payload = payload
        self.tools = payload.verbs
            .filter { !Self.excludedVerbPaths.contains($0.name) }
            .map(Self.tool(for:))
    }

    static func toolName(forVerbPath verbPath: String) -> String {
        verbPath.replacingOccurrences(of: " ", with: "_")
    }

    func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    func verb(forToolName name: String) -> CapabilitiesVerbPayload? {
        tool(named: name)?.verb
    }

    func exitCodeMeaning(_ code: Int32) -> String {
        payload.exitCodes.first { $0.code == code }?.meaning ?? "Unknown exit code."
    }

    private static func tool(for verb: CapabilitiesVerbPayload) -> MCPTool {
        var description = verb.abstract
        if !verb.inputSchema.conflicts.isEmpty {
            description += "\n\nConstraints:\n" + verb.inputSchema.conflicts.map { "- \($0.description)" }.joined(separator: "\n")
        }
        var properties: [String: MCPJSONValue] = [:]
        for (key, property) in verb.inputSchema.properties where key != jsonProperty {
            var schema: [String: MCPJSONValue] = [
                "type": .string(property.type),
                "description": .string(property.description),
            ]
            if property.type == "array" {
                schema["items"] = .object(["type": .string("string")])
            }
            if let values = property.enumValues {
                schema["enum"] = .array(values.map(MCPJSONValue.string))
            }
            if let minimum = property.minimum {
                schema["minimum"] = .int(minimum)
            }
            if let maximum = property.maximum {
                schema["maximum"] = .int(maximum)
            }
            if let value = property.defaultValue, let typed = typedDefault(value, type: property.type) {
                schema["default"] = typed
            }
            properties[key] = .object(schema)
        }
        let required = verb.inputSchema.required.filter { $0 != jsonProperty }.sorted()
        let inputSchema: MCPJSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(MCPJSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        return MCPTool(
            name: toolName(forVerbPath: verb.name),
            description: description,
            inputSchema: inputSchema,
            annotations: verb.annotations,
            verb: verb
        )
    }

    private static func typedDefault(_ value: String, type: String) -> MCPJSONValue? {
        switch type {
        case "boolean": Bool(value).map(MCPJSONValue.bool)
        case "integer": Int(value).map(MCPJSONValue.int)
        // A whole number stays `.int`, the form it decodes back to from JSON.
        case "number": Int(value).map(MCPJSONValue.int) ?? Double(value).map(MCPJSONValue.double)
        default: .string(value)
        }
    }

    /// Validates a `tools/call`'s arguments and builds the argv for the verb:
    /// options as `--long=value`, boolean flags only when true, an enum-flag
    /// as its own spelling, `--json` when available, the positional (each element
    /// of an array positional as its own argument) last after `--`.
    func arguments(forToolName name: String, callArguments: [String: MCPJSONValue]) throws(MCPArgumentError) -> [String] {
        guard let verb = verb(forToolName: name) else { throw .unknownArgument(name) }
        let properties = verb.inputSchema.properties
        for (key, value) in callArguments {
            guard key != Self.jsonProperty, let property = properties[key] else { throw .unknownArgument(key) }
            try Self.validate(value, for: property, named: key)
        }
        for key in verb.inputSchema.required where key != Self.jsonProperty && callArguments[key] == nil {
            throw .missingRequired(key)
        }

        var argv = verb.name.split(separator: " ").map(String.init)
        var positional: [String] = []
        for key in callArguments.keys.sorted() {
            guard let property = properties[key], let value = callArguments[key] else { continue }
            switch property.cliKind {
            case .positional:
                if case let .array(elements) = value {
                    positional = elements.map(\.argumentText)
                } else {
                    positional = [value.argumentText]
                }
            case .option:
                argv.append("\(Self.longName(property))=\(value.argumentText)")
            case .flag:
                if case let .bool(isSet) = value {
                    if isSet { argv.append(Self.longName(property)) }
                } else if case let .string(choice) = value, let spelling = property.enumValueNames?[choice]?.last {
                    argv.append(spelling)
                }
            }
        }
        if properties[Self.jsonProperty] != nil && !Self.jsonExcluded(by: callArguments, conflicts: verb.inputSchema.conflicts) {
            argv.append("--json")
        }
        if !positional.isEmpty {
            argv += ["--"] + positional
        }
        return argv
    }

    private static func longName(_ property: CapabilitiesPropertyPayload) -> String {
        property.names.first { $0.hasPrefix("--") } ?? property.names.first ?? ""
    }

    private static func jsonExcluded(by callArguments: [String: MCPJSONValue], conflicts: [CapabilitiesConstraintPayload]) -> Bool {
        conflicts.contains { conflict in
            guard conflict.kind == .mutuallyExclusive, let parameters = conflict.parameters, parameters.contains(jsonProperty) else { return false }
            return parameters.contains { $0 != jsonProperty && (callArguments[$0]?.isSet ?? false) }
        }
    }

    private static func validate(_ value: MCPJSONValue, for property: CapabilitiesPropertyPayload, named key: String) throws(MCPArgumentError) {
        switch (property.type, value) {
        case ("boolean", .bool):
            break
        case let ("integer", .int(number)):
            if let minimum = property.minimum, number < minimum { throw .belowMinimum(key, minimum: minimum) }
            if let maximum = property.maximum, number > maximum { throw .aboveMaximum(key, maximum: maximum) }
        case let ("number", .int(number)):
            if let maximum = property.maximum, number > maximum { throw .aboveMaximum(key, maximum: maximum) }
        case let ("number", .double(number)):
            if let maximum = property.maximum, !(number <= Double(maximum)) { throw .aboveMaximum(key, maximum: maximum) }
        case let ("string", .string(text)):
            if let allowed = property.enumValues, !allowed.contains(text) { throw .notInEnum(key, allowed: allowed) }
        case let ("array", .array(elements)):
            // Array properties are string lists (a trailing `-- <command…>`).
            for element in elements {
                guard case .string = element else { throw .wrongType(key, expected: "array of strings") }
            }
        default:
            throw .wrongType(key, expected: property.type)
        }
    }
}

private nonisolated extension MCPJSONValue {
    var argumentText: String {
        switch self {
        case let .string(text): text
        case let .int(number): String(number)
        case let .double(number): String(number)
        case let .bool(flag): String(flag)
        case .null, .array, .object: ""
        }
    }

    var isSet: Bool {
        switch self {
        case let .bool(flag): flag
        case .null: false
        default: true
        }
    }
}
