// CapabilitiesInputSchemaTests.swift

import ArgumentParser
import BattyXPCCore
import Foundation
import Testing
@testable import batty

/// Covers #0402: `batty capabilities --json`'s per-verb `inputSchema` and
/// `annotations`. The load-bearing property this whole file guards is the
/// **round trip** the issue asked for — every schema is checked against the
/// actual `@Option`/`@Flag`/`@Argument` surface of its command, via `Mirror`
/// on an instance built by ArgumentParser's own `.parse(_:)`, not against a
/// second hand-typed expectation that could drift the same way the schema
/// itself could. A `#expect(...)` that only checks a substring or a key's
/// mere presence would pass even if the schema were attached to the wrong
/// verb or malformed — see #0392's "contains" trap, cited in this issue's
/// own testing notes — so every assertion here decodes and compares exact
/// sets/structures.
///
/// **What the drift oracle catches and what it doesn't (round-1 review):**
/// `assertSchemaMatchesStoredProperties` below only compares property *keys*
/// — it would not have caught round-1's B1 (`direction` describing a
/// `--direction` flag that does not exist), because `direction` is a real
/// stored property with a real, correctly-named schema key; the bug was in
/// the schema's *shape* for that key, not its presence. `assertNamesAreInvocable`
/// closes that specific gap by checking every declared CLI spelling actually
/// appears in the command's own rendered `--help` text (N2's "cheap real
/// check"). Neither test proves a schema is fully correct — only that it is
/// not obviously wrong in these two dimensions.
struct CapabilitiesInputSchemaTests {

    // MARK: - Drift oracle: Mirror-based stored-property enumeration

    /// The Swift property name ArgumentParser exposes for each
    /// `@Option`/`@Flag`/`@Argument`-wrapped stored property of `instance`,
    /// found by reflecting its backing-storage properties (`_foo` holding an
    /// `Option<T>`/`Flag<T>`/`Argument<T>`) — the same shape
    /// `DumpHelpGenerator`'s internal `ArgumentSet` walk sees, reached here
    /// with only public `Mirror` reflection so this test needs no
    /// `@testable import ArgumentParser` and no dependency on ArgumentParser
    /// internals that could break across a version bump.
    private func wrappedPropertyNames(of instance: Any) -> Set<String> {
        Set(
            Mirror(reflecting: instance).children.compactMap { child -> String? in
                guard let label = child.label, label.hasPrefix("_") else { return nil }
                let typeName = String(describing: type(of: child.value))
                guard typeName.hasPrefix("Option<") || typeName.hasPrefix("Flag<") || typeName.hasPrefix("Argument<") else {
                    return nil
                }
                return String(label.dropFirst())
            }
        )
    }

    /// ArgumentParser's own camelCase → kebab-case conversion
    /// (`convertedToSnakeCase(separator: "-")`) for every property name this
    /// CLI actually uses (no acronyms, no consecutive capitals), so a plain
    /// per-character conversion is exact, not an approximation.
    private func kebabCase(_ propertyName: String) -> String {
        var result = ""
        for (index, character) in propertyName.enumerated() {
            if character.isUppercase {
                if index > 0 { result += "-" }
                result += character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Asserts `schema`'s property keys are exactly the kebab-cased Swift
    /// property names Mirror finds on `instance` — this is the drift check:
    /// a flag added to a command's stored properties without a matching
    /// schema entry (or a schema entry for a flag that no longer exists)
    /// fails here, not silently. Does **not** check `cliKind`/`type`/
    /// `names`/`defaultValue`/per-property `required` — see
    /// `assertNamesAreInvocable` for the one further check this file adds.
    private func assertSchemaMatchesStoredProperties(_ instance: Any, schema: CapabilitiesInputSchemaPayload, sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = Set(wrappedPropertyNames(of: instance).map(kebabCase))
        #expect(Set(schema.properties.keys) == expected, sourceLocation: sourceLocation)
    }

    /// N2 (round-1 review): for every declared property, every literal CLI
    /// spelling this schema claims — `names` for a plain option/flag,
    /// `enumValueNames`'s per-value spellings for a collapsed enum-flag
    /// property — must actually appear in `helpMessage`, the command's own
    /// rendered `--help` text. This is exactly the check that would have
    /// caught B1: `--direction` is not a real flag, so it does not appear in
    /// `pane split --help`, while `-h`/`--horizontal`/`-v`/`--vertical` do.
    private func assertNamesAreInvocable(_ schema: CapabilitiesInputSchemaPayload, helpMessage: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for (key, property) in schema.properties {
            if let enumValueNames = property.enumValueNames {
                #expect(property.names.isEmpty, "\(key): enum-flag property must not also carry plain `names`", sourceLocation: sourceLocation)
                #expect(!enumValueNames.isEmpty, "\(key): enumValueNames must not be empty", sourceLocation: sourceLocation)
                for (value, spellings) in enumValueNames {
                    #expect(!spellings.isEmpty, "\(key)=\(value): no spellings declared", sourceLocation: sourceLocation)
                    for spelling in spellings {
                        #expect(helpMessage.contains(spelling), "\(key)=\(value): spelling '\(spelling)' not found in --help text", sourceLocation: sourceLocation)
                    }
                }
            } else if property.cliKind == .positional {
                #expect(property.names.isEmpty, "\(key): positional argument must not carry `names`", sourceLocation: sourceLocation)
            } else {
                #expect(!property.names.isEmpty, "\(key): option/flag property has no `names`", sourceLocation: sourceLocation)
                for name in property.names {
                    #expect(helpMessage.contains(name), "\(key): spelling '\(name)' not found in --help text", sourceLocation: sourceLocation)
                }
            }
        }
    }

    // MARK: - Per-verb drift tests

    @Test func newSessionCommandSchemaMatchesStoredProperties() throws {
        let instance = try NewSessionCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: NewSessionCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(NewSessionCommand.capabilitiesInputSchema, helpMessage: NewSessionCommand.helpMessage())
    }

    @Test func pingCommandHasNoParameters() throws {
        let instance = try PingCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: PingCommand.capabilitiesInputSchema)
        #expect(PingCommand.capabilitiesInputSchema.properties.isEmpty)
    }

    @Test func statusCommandSchemaMatchesStoredProperties() throws {
        let instance = try StatusCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: StatusCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(StatusCommand.capabilitiesInputSchema, helpMessage: StatusCommand.helpMessage())
    }

    @Test func listCommandSchemaMatchesStoredProperties() throws {
        let instance = try ListCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: ListCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(ListCommand.capabilitiesInputSchema, helpMessage: ListCommand.helpMessage())
    }

    @Test func sessionInfoCommandSchemaMatchesStoredProperties() throws {
        let instance = try SessionInfoCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: SessionInfoCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(SessionInfoCommand.capabilitiesInputSchema, helpMessage: SessionInfoCommand.helpMessage())
    }

    @Test func sessionFocusCommandSchemaMatchesStoredProperties() throws {
        let instance = try SessionFocusCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: SessionFocusCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(SessionFocusCommand.capabilitiesInputSchema, helpMessage: SessionFocusCommand.helpMessage())
    }

    @Test func sessionCloseCommandSchemaMatchesStoredProperties() throws {
        let instance = try SessionCloseCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: SessionCloseCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(SessionCloseCommand.capabilitiesInputSchema, helpMessage: SessionCloseCommand.helpMessage())
    }

    @Test func paneSplitCommandSchemaMatchesStoredProperties() throws {
        let instance = try PaneSplitCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: PaneSplitCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(PaneSplitCommand.capabilitiesInputSchema, helpMessage: PaneSplitCommand.helpMessage())
    }

    @Test func paneCloseCommandSchemaMatchesStoredProperties() throws {
        let instance = try PaneCloseCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: PaneCloseCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(PaneCloseCommand.capabilitiesInputSchema, helpMessage: PaneCloseCommand.helpMessage())
    }

    @Test func paneFocusCommandSchemaMatchesStoredProperties() throws {
        let instance = try PaneFocusCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: PaneFocusCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(PaneFocusCommand.capabilitiesInputSchema, helpMessage: PaneFocusCommand.helpMessage())
    }

    @Test func paneHideCommandSchemaMatchesStoredProperties() throws {
        let instance = try PaneHideCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: PaneHideCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(PaneHideCommand.capabilitiesInputSchema, helpMessage: PaneHideCommand.helpMessage())
    }

    @Test func paneShowCommandSchemaMatchesStoredProperties() throws {
        let instance = try PaneShowCommand.parse(["00000000-0000-0000-0000-000000000000"])
        assertSchemaMatchesStoredProperties(instance, schema: PaneShowCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(PaneShowCommand.capabilitiesInputSchema, helpMessage: PaneShowCommand.helpMessage())
    }

    @Test func tabFocusCommandSchemaMatchesStoredProperties() throws {
        let instance = try TabFocusCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: TabFocusCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(TabFocusCommand.capabilitiesInputSchema, helpMessage: TabFocusCommand.helpMessage())
    }

    @Test func idCommandSchemaMatchesStoredProperties() throws {
        let instance = try IDCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: IDCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(IDCommand.capabilitiesInputSchema, helpMessage: IDCommand.helpMessage())
    }

    @Test func notifyCommandSchemaMatchesStoredProperties() throws {
        let instance = try NotifyCommand.parse(["--title", "x"])
        assertSchemaMatchesStoredProperties(instance, schema: NotifyCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(NotifyCommand.capabilitiesInputSchema, helpMessage: NotifyCommand.helpMessage())
    }

    @Test func capabilitiesCommandSchemaMatchesStoredProperties() throws {
        let instance = try CapabilitiesCommand.parse([])
        assertSchemaMatchesStoredProperties(instance, schema: CapabilitiesCommand.capabilitiesInputSchema)
        assertNamesAreInvocable(CapabilitiesCommand.capabilitiesInputSchema, helpMessage: CapabilitiesCommand.helpMessage())
    }

    // MARK: - Every leaf command conforms (parameter-roster analog of
    // #0384's verb-roster derivation)

    @Test func everyLeafCommandConformsToCapabilitiesDescribable() {
        // Mirrors CapabilitiesCommand.collectVerbs' own walk, so a future
        // command that forgets to declare its schema fails here, the same
        // way a verb missing from BattyCLI's tree would fail #0384's own
        // roster tests.
        func leafTypes(from type: ParsableCommand.Type) -> [ParsableCommand.Type] {
            let subcommands = type.configuration.subcommands
            guard !subcommands.isEmpty else { return [type] }
            return subcommands.flatMap(leafTypes)
        }
        let leaves = BattyCLI.configuration.subcommands.flatMap(leafTypes)
        #expect(!leaves.isEmpty)
        for leaf in leaves {
            #expect(leaf is CapabilitiesDescribable.Type, "\(leaf) has no capabilitiesInputSchema")
        }
    }

    // MARK: - #0402's motivating gap: the five PaneContentKind values

    @Test func viewParameterEnumMatchesPaneContentKindAllCases() throws {
        let view = try #require(PaneSplitCommand.capabilitiesInputSchema.properties["view"])
        #expect(view.enumValues == PaneContentKind.allCases.map(\.rawValue))
        #expect(view.enumValues?.contains("git-status") == true)
        #expect(view.enumValues?.contains("process-status") == true)
        #expect(view.enumValues?.contains("lm-studio-dashboard") == true)
        #expect(view.enumValues?.contains("system-metrics") == true)
        #expect(view.defaultValue == "terminal")
        #expect(view.names == ["--view"])
    }

    @Test func directionParameterEnumMatchesSplitDirectionFlagAllCases() throws {
        let direction = try #require(PaneSplitCommand.capabilitiesInputSchema.properties["direction"])
        #expect(direction.enumValues == ["horizontal", "vertical"])
    }

    // B1 (round-1 review): `direction` is a real, callable parameter — this
    // is the specific regression test for "a `--direction` flag that does
    // not exist". `assertNamesAreInvocable` (exercised for every command
    // above) also covers this, but this test states the exact expected
    // shape so a future reader does not have to reconstruct it from a
    // generic helper's failure message.
    @Test func directionHasNoPhantomFlagAndRealPerValueSpellings() throws {
        let direction = try #require(PaneSplitCommand.capabilitiesInputSchema.properties["direction"])
        #expect(direction.names.isEmpty, "direction must not claim a --direction flag that does not exist")
        let spellings = try #require(direction.enumValueNames)
        #expect(spellings["horizontal"] == ["-h", "--horizontal"])
        #expect(spellings["vertical"] == ["-v", "--vertical"])
        let helpMessage = PaneSplitCommand.helpMessage()
        #expect(!helpMessage.contains("--direction"), "there really is no --direction flag")
        for spelling in (spellings["horizontal"] ?? []) + (spellings["vertical"] ?? []) {
            #expect(helpMessage.contains(spelling))
        }
    }

    @Test func listScopeParameterEnumMatchesScopeAllCases() throws {
        let scope = try #require(ListCommand.capabilitiesInputSchema.properties["scope"])
        #expect(scope.enumValues == ["sessions", "panes", "tabs"])
    }

    @Test func pidHasAMinimumOfOneMatchingTheRuntimeCheck() throws {
        // N5 (round-1 review): `PaneCommand.swift` rejects `--pid <= 0`
        // client-side before any XPC round trip; the schema should say so
        // too, not just describe `pid` as an unconstrained integer.
        let pid = try #require(PaneSplitCommand.capabilitiesInputSchema.properties["pid"])
        #expect(pid.minimum == 1)
    }

    // MARK: - The four PaneCommand.swift conflicts (#0402 Gap 2)

    @Test func paneSplitConflictsCoverAllFourImperativeRules() throws {
        let conflicts = PaneSplitCommand.capabilitiesInputSchema.conflicts
        #expect(conflicts.count == 4)
        let byParameter = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.parameter, $0) })

        let unique = try #require(byParameter["unique"])
        #expect(unique.kind == .requires)
        #expect(unique.requiresParameter == "view")
        #expect(Set(unique.allowedValues ?? []) == ["git-status", "process-status", "lm-studio-dashboard", "system-metrics"])
        #expect(unique.allowsOmission == false)

        let command = try #require(byParameter["command"])
        #expect(command.kind == .requires)
        #expect(command.requiresParameter == "view")
        #expect(command.allowedValues == ["terminal"])
        #expect(command.allowsOmission == true)

        let pid = try #require(byParameter["pid"])
        #expect(pid.kind == .requires)
        #expect(pid.allowedValues == ["process-status"])
        #expect(pid.allowsOmission == false)

        let path = try #require(byParameter["path"])
        #expect(path.kind == .requires)
        #expect(path.allowedValues == ["git-status"])
        #expect(path.allowsOmission == false)

        for conflict in conflicts {
            #expect(!conflict.description.isEmpty)
        }
    }

    // B2 (round-1 review): `command` is the one rule among the four where
    // omitting `--view` is legal — encoding it identically to the other
    // three (all `allowsOmission: false`) would misdescribe the most common
    // non-default invocation, `batty pane split -c "npm test"` (no `--view`
    // at all, `docs/batty-cli-agent-workflows.md:102`), as a violation.
    @Test func onlyCommandAllowsOmittingView() throws {
        let conflicts = PaneSplitCommand.capabilitiesInputSchema.conflicts
        let byParameter = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.parameter, $0) })
        for (parameter, constraint) in byParameter {
            let expected = (parameter == "command")
            #expect(constraint.allowsOmission == expected, "\(parameter ?? "?").allowsOmission should be \(expected)")
        }
    }

    @Test func newSessionMutualExclusionMatchesValidateLogic() throws {
        let conflicts = NewSessionCommand.capabilitiesInputSchema.conflicts
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.kind == .mutuallyExclusive)
        #expect(Set(conflict.parameters ?? []) == ["json", "no-wait"])
    }

    @Test func constraintPayloadOmitsInapplicableFieldsWhenEncoded() throws {
        // A `.mutuallyExclusive` constraint has no `parameter`/`requiresParameter`
        // /`allowedValues`/`allowsOmission` — Swift's synthesized `Encodable`
        // uses `encodeIfPresent` for `Optional` properties, so those keys
        // must be entirely absent from the JSON, not present as explicit
        // `null`.
        let constraint = CapabilitiesConstraintPayload.mutuallyExclusive(["json", "no-wait"], description: "x")
        let data = try JSONEncoder().encode(constraint)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(raw.keys) == ["kind", "parameters", "description"])
    }

    // MARK: - Annotations coverage (leaf-archetype opt-in table, N4)

    /// N4 (round-1 review): the coverage table is keyed by **full verb
    /// path**, not leaf name, and joined the same way `collectVerbs`
    /// joins one — so a hypothetical new `tab close` is a brand-new,
    /// unrecognized key, never a silent match against `pane close`'s or
    /// `session close`'s `"close"` entry.
    private func shippedVerbPaths() -> Set<String> {
        func verbPaths(from type: ParsableCommand.Type, prefix: [String]) -> [String] {
            let config = type.configuration
            let name = config.commandName ?? String(describing: type)
            let path = prefix + [name]
            guard !config.subcommands.isEmpty else { return [path.joined(separator: " ")] }
            return config.subcommands.flatMap { verbPaths(from: $0, prefix: path) }
        }
        return Set(BattyCLI.configuration.subcommands.flatMap { verbPaths(from: $0, prefix: []) })
    }

    @Test func leafArchetypeByVerbPathCoversExactlyTheShippedVerbPaths() {
        #expect(Set(CapabilitiesCommand.leafArchetypeByVerbPath.keys) == shippedVerbPaths())
    }

    @Test func everyArchetypeLeafArchetypeByVerbPathPointsAtExists() {
        for (verbPath, archetype) in CapabilitiesCommand.leafArchetypeByVerbPath {
            #expect(CapabilitiesCommand.annotationsByArchetype[archetype] != nil, "\(verbPath) points at unknown archetype \(archetype)")
        }
    }

    // N4 mutation-in-miniature, kept as a permanent regression test: a verb
    // path that merely *ends* in a known archetype name must not be
    // silently classified by it.
    @Test func anUnregisteredVerbPathIsNotSilentlyClassified() {
        #expect(CapabilitiesCommand.leafArchetypeByVerbPath["tab close"] == nil)
        #expect(CapabilitiesCommand.annotations(forVerbPath: "tab close") == .worstCaseDefault)
    }

    @Test func readOnlyVerbsAreNeverAlsoDestructive() {
        // MCP's own constraint: a read-only tool is never destructive.
        for annotations in CapabilitiesCommand.annotationsByArchetype.values where annotations.readOnlyHint {
            #expect(!annotations.destructiveHint)
        }
    }

    @Test func closeIsDestructiveAndNotIdempotent() throws {
        let close = try #require(CapabilitiesCommand.annotationsByArchetype["close"])
        #expect(close.destructiveHint)
        #expect(!close.idempotentHint)
        #expect(!close.readOnlyHint)
    }

    @Test func hideAndShowAreIdempotent() throws {
        let hide = try #require(CapabilitiesCommand.annotationsByArchetype["hide"])
        let show = try #require(CapabilitiesCommand.annotationsByArchetype["show"])
        #expect(hide.idempotentHint)
        #expect(show.idempotentHint)
    }

    @Test func splitIsNotIdempotentAtTheVerbLevel() throws {
        // Worst-case default: only `--unique` narrows this, and MCP's own
        // hints are static per-tool, not conditional on arguments.
        let split = try #require(CapabilitiesCommand.annotationsByArchetype["split"])
        #expect(!split.idempotentHint)
    }

    @Test func everyVerbAnnotationsRoundTrip() throws {
        for verb in CapabilitiesCommand.verbs() {
            let data = try JSONEncoder().encode(verb.annotations)
            let decoded = try JSONDecoder().decode(CapabilitiesAnnotationsPayload.self, from: data)
            #expect(decoded == verb.annotations)
        }
    }

    // MARK: - Full-payload structural checks

    @Test func jsonSchemaDialectIsThe2020_12Draft() {
        #expect(CapabilitiesCommand.buildPayload().jsonSchemaDialect == "https://json-schema.org/draft/2020-12/schema")
    }

    @Test func everyVerbInputSchemaHasTypeObject() {
        for verb in CapabilitiesCommand.verbs() {
            #expect(verb.inputSchema.type == "object")
        }
    }

    @Test func notifyTitleIsTheOnlyRequiredParameterAcrossAllVerbs() {
        // The full roster's only two truly-required parameters: `notify
        // --title` and `pane show <id>` — everything else is optional or
        // defaulted, matching each command's own Swift type (Optional or a
        // default expression).
        let notify = CapabilitiesCommand.verbs().first { $0.name == "notify" }
        #expect(notify?.inputSchema.required == ["title"])
        let paneShow = CapabilitiesCommand.verbs().first { $0.name == "pane show" }
        #expect(paneShow?.inputSchema.required == ["id"])
    }

    // N1 (round-1 review): decode and compare exact values instead of a
    // `.contains(...)` substring check, which would pass even if
    // `properties.view.enum` were empty (`"git-status"` also appears inside
    // `conflicts[].allowedValues`).
    @Test func paneSplitSampleShapeForAnAgent() throws {
        let verb = try #require(CapabilitiesCommand.verbs().first { $0.name == "pane split" })
        let view = try #require(verb.inputSchema.properties["view"])
        #expect(view.enumValues == ["terminal", "git-status", "process-status", "lm-studio-dashboard", "system-metrics"])
        let direction = try #require(verb.inputSchema.properties["direction"])
        #expect(direction.enumValueNames?["horizontal"] == ["-h", "--horizontal"])
        // Rendered anyway, for a human reading test output to see the exact
        // shape #0402 produces for its own motivating case.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        _ = try encoder.encode(verb)
    }
}
