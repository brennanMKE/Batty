// CapabilitiesInputSchemaPayload.swift

import Foundation

/// MCP-shaped (`tools/list`, spec rev 2026-07-28) per-verb call surface for
/// `batty capabilities --json` (#0402): every parameter of every verb, with
/// enum-valued parameters carrying their allowed values, plus the
/// cross-parameter conflicts that live only in imperative validation code
/// today (`PaneCommand.swift`, `NewSessionCommand.validate()`). Additive to
/// #0384's `{name, abstract, aliases}` verb shape — those keys are
/// untouched.
///
/// `BattyXPCCore` must not depend on `ArgumentParser` (same discipline
/// `PaneContentKind`'s and `XPCExitCode`'s own doc comments already state
/// for the CLI/broker split), so these are plain JSON-Schema-shaped value
/// types with no ArgumentParser types embedded; `CapabilitiesCommand`
/// (which already imports `ArgumentParser`) is what builds one per verb,
/// **by hand, per command** — this is not derived from ArgumentParser's own
/// argument metadata (see `CapabilitiesCommand.swift`'s
/// `CapabilitiesDescribable` doc comment for why not). What keeps a
/// hand-authored schema honest is `CapabilitiesInputSchemaTests`' Mirror-based
/// drift oracle, not this file's own types.
public nonisolated struct CapabilitiesPropertyPayload: Codable, Sendable, Equatable {
    /// How this parameter is written on the command line. Not part of bare
    /// JSON Schema/MCP — schema `properties` alone cannot distinguish "a
    /// bare positional value" from "`--flag value`" from "a valueless
    /// `--flag` switch", and telling an agent that apart is the entire
    /// point of this issue: knowing a parameter's name, type, and enum
    /// values is not enough to construct a real invocation without it.
    ///
    /// `.flag` covers two distinct shapes, disambiguated by which of
    /// `names`/`enumValueNames` is populated (never both):
    /// - A plain boolean switch (`--unique`): `names` holds its one
    ///   spelling, `enumValues`/`enumValueNames` are both `nil`.
    /// - An `EnumerableFlag` pair collapsed into one logical parameter
    ///   (`pane split`'s `direction`, backed by `-h/--horizontal` and
    ///   `-v/--vertical`, two real flags, not one): `names` is empty,
    ///   `enumValues` names the logical values, and `enumValueNames` gives
    ///   each value's own real spelling. There is no single `--direction`
    ///   flag to put in `names` — #0402's round-1 review caught a payload
    ///   that implied there was.
    public nonisolated enum CLIKind: String, Codable, Sendable, Equatable {
        case option
        case flag
        case positional
    }

    public let cliKind: CLIKind
    /// The literal spelling(s) this parameter is invoked with — e.g.
    /// `["--pane"]`, `["-c", "--command"]`. Empty for a positional argument
    /// (nothing precedes the value) and for an enum-flag property (see
    /// `enumValueNames` instead).
    public let names: [String]
    /// JSON Schema `type`: `"string"`, `"boolean"`, or `"integer"`.
    public let type: String
    public let description: String
    public let required: Bool
    /// JSON Schema `enum` — populated for every enum-backed parameter
    /// (`pane split --view`, `pane split --direction`, `list`'s positional
    /// `scope`). This is the field the five `PaneContentKind` values were
    /// entirely absent from before #0402.
    public let enumValues: [String]?
    /// Per-value CLI spelling, populated only for an enum-flag property
    /// (`names` empty) — e.g. `direction`'s `{"horizontal": ["-h",
    /// "--horizontal"], "vertical": ["-v", "--vertical"]}`. `nil` for every
    /// other property: an `--option <value>` property's `names` already
    /// says how to invoke it, and the enum value is passed through as-is
    /// (`--view git-status`), needing no per-value spelling of its own.
    public let enumValueNames: [String: [String]]?
    /// String form of the value applied when this parameter is omitted,
    /// matching `ArgumentParserToolInfo.ArgumentInfoV0.defaultValue`'s own
    /// convention (always a string, regardless of the underlying type).
    public let defaultValue: String?
    /// JSON Schema `minimum` — populated only for an integer parameter with
    /// a runtime lower bound (`pane split --pid`, rejected client-side at
    /// `PaneCommand.swift` when non-positive).
    public let minimum: Int?

    enum CodingKeys: String, CodingKey {
        case cliKind
        case names
        case type
        case description
        case required
        case enumValues = "enum"
        case enumValueNames
        case defaultValue = "default"
        case minimum
    }

    public init(
        cliKind: CLIKind,
        names: [String] = [],
        type: String,
        description: String,
        required: Bool,
        enumValues: [String]? = nil,
        enumValueNames: [String: [String]]? = nil,
        defaultValue: String? = nil,
        minimum: Int? = nil
    ) {
        self.cliKind = cliKind
        self.names = names
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
        self.enumValueNames = enumValueNames
        self.defaultValue = defaultValue
        self.minimum = minimum
    }
}

/// One cross-parameter constraint invisible to any per-argument dump
/// (#0402's Gap 2) — `PaneCommand.swift`'s four `if` statements
/// (`--unique`/`--command`/`--pid`/`--path` against `--view`) and
/// `NewSessionCommand.validate()`'s `--json`/`--no-wait` exclusion — stated
/// structurally so a calling agent can act on them without parsing English,
/// rather than left only in Swift validation code or free-text description
/// fields the way MCP itself would leave them.
public nonisolated struct CapabilitiesConstraintPayload: Codable, Sendable, Equatable {
    public nonisolated enum Kind: String, Codable, Sendable, Equatable {
        /// `parameter` may only be supplied when either: `requiresParameter`
        /// is supplied and holds one of `allowedValues`, or
        /// `requiresParameter` is omitted entirely **and** `allowsOmission`
        /// is `true`. `allowsOmission` is `false` for a rule where omitting
        /// `requiresParameter` is itself a violation (`pane split`'s
        /// `unique`/`pid`/`path`, each of which requires `view` to be
        /// **present** and equal to a specific value) — `true` only where
        /// omission also satisfies the rule (`command`, valid whether
        /// `view` is omitted or explicitly `terminal`). Round-1 review
        /// caught this codebase's own version of #0402's motivating problem:
        /// without `allowsOmission`, all four rules encoded identically and
        /// an agent had to read English to tell `command`'s escape hatch
        /// apart from the other three.
        case requires
        /// No more than one name in `parameters` may be set at the same
        /// time.
        case mutuallyExclusive
    }

    public let kind: Kind
    /// `.requires` only: the parameter this constraint governs.
    public let parameter: String?
    /// `.requires` only: the other parameter it is stated in terms of.
    public let requiresParameter: String?
    /// `.requires` only: the values `requiresParameter` may hold for
    /// `parameter` to be usable.
    public let allowedValues: [String]?
    /// `.requires` only: see `Kind.requires`'s doc comment.
    public let allowsOmission: Bool?
    /// `.mutuallyExclusive` only: the parameters that cannot all be set
    /// together.
    public let parameters: [String]?
    /// Agent/human-readable statement modeling the runtime validation this
    /// constraint describes. **Hand-authored, not verified against
    /// `PaneCommand`'s/`NewSessionCommand`'s `fputs`/`ValidationError` text
    /// by any test** — round-1 review found an earlier version of this
    /// comment claiming otherwise, which was false: two of the four `pane
    /// split` messages interpolate the offending `--view` value at runtime
    /// (`--path is not valid with --view \(kindDescription) ...`), so no
    /// static string here can match them verbatim, and
    /// `CapabilitiesInputSchemaTests` only asserts this field is non-empty.
    /// Where the real message is a fixed string (`unique`, `pid`), this
    /// text matches it verbatim apart from the `batty: ` prefix and
    /// trailing newline; where it isn't (`command`, `path`), this is a
    /// paraphrase using a `<kind>` placeholder instead of an interpolated
    /// value.
    public let description: String

    public init(
        kind: Kind,
        parameter: String? = nil,
        requiresParameter: String? = nil,
        allowedValues: [String]? = nil,
        allowsOmission: Bool? = nil,
        parameters: [String]? = nil,
        description: String
    ) {
        self.kind = kind
        self.parameter = parameter
        self.requiresParameter = requiresParameter
        self.allowedValues = allowedValues
        self.allowsOmission = allowsOmission
        self.parameters = parameters
        self.description = description
    }

    public static func requires(
        parameter: String,
        requiresParameter: String,
        allowedValues: [String],
        allowsOmission: Bool,
        description: String
    ) -> Self {
        .init(kind: .requires, parameter: parameter, requiresParameter: requiresParameter, allowedValues: allowedValues, allowsOmission: allowsOmission, description: description)
    }

    public static func mutuallyExclusive(_ parameters: [String], description: String) -> Self {
        .init(kind: .mutuallyExclusive, parameters: parameters, description: description)
    }
}

/// A verb's `inputSchema`: JSON Schema `{type: "object", properties,
/// required}` — the MCP shape — plus `conflicts` for what JSON Schema alone
/// cannot express cleanly (#0402's Gap 2). The dialect itself
/// (`https://json-schema.org/draft/2020-12/schema`, per MCP) is stated once,
/// at `CapabilitiesPayload.jsonSchemaDialect`, rather than repeated
/// identically on every verb.
public nonisolated struct CapabilitiesInputSchemaPayload: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: CapabilitiesPropertyPayload]
    public let required: [String]
    public let conflicts: [CapabilitiesConstraintPayload]

    public init(
        properties: [String: CapabilitiesPropertyPayload] = [:],
        required: [String] = [],
        conflicts: [CapabilitiesConstraintPayload] = []
    ) {
        self.type = "object"
        self.properties = properties
        self.required = required
        self.conflicts = conflicts
    }

    /// A verb with no parameters at all (`ping`) — still a well-formed,
    /// empty JSON Schema object, not an absent field.
    public static let empty = CapabilitiesInputSchemaPayload()
}

/// MCP `tools/list`'s behavioral hints (spec since rev 2025-03-26): hints,
/// not guarantees, "with worst-case defaults" per the spec's own wording.
/// See `CapabilitiesCommand.annotations(forVerbPath:)` for how these are
/// assigned to each verb and what "derived" honestly means for that table.
public nonisolated struct CapabilitiesAnnotationsPayload: Codable, Sendable, Equatable {
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
    public let idempotentHint: Bool
    public let openWorldHint: Bool

    public init(readOnlyHint: Bool, destructiveHint: Bool, idempotentHint: Bool, openWorldHint: Bool) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    /// MCP's own documented defaults for an *unannotated* tool — used here
    /// only as the fallback for a verb path with no entry in
    /// `CapabilitiesCommand.leafArchetypeByVerbPath`, which
    /// `CapabilitiesInputSchemaTests` asserts never actually happens for any
    /// verb this build ships. Assuming the worst (mutating, destructive,
    /// non-idempotent, open-world) is the spec's own stance for the unknown
    /// case, not a value this codebase invented.
    public static let worstCaseDefault = CapabilitiesAnnotationsPayload(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
    )
}
