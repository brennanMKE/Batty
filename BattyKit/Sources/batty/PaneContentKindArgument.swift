// PaneContentKindArgument.swift

import ArgumentParser
import BattyXPCCore

/// Retypes `pane split --view` from a hand-validated `String?` to this enum
/// (#0402 Gap 1) so ArgumentParser's own metadata carries the pane-kind
/// vocabulary. `allValueStrings`/`init?(argument:)` come free from
/// `PaneContentKind` already being a `String`-backed `RawRepresentable &
/// CaseIterable` enum — `ExpressibleByArgument`'s own conditional extension
/// (`Self: CaseIterable & RawRepresentable, RawValue: ExpressibleByArgument`)
/// derives `allValueStrings` as `allCases.map(\.rawValue)`, and
/// `RawRepresentable`'s own conditional extension derives `init?(argument:)`
/// from `String`'s conformance — no code needed beyond this conformance
/// declaration. An unknown `--view` value is now ArgumentParser's own parse
/// error (exit `64`, `docs/batty-cli-agent-workflows.md`'s exit-code table)
/// instead of `PaneCommand.swift`'s former hand-rolled exit-`1` check.
///
/// Lives in the `batty` target, not `BattyXPCCore`, which must not depend on
/// `ArgumentParser` — `PaneContentKind`'s own doc comment already states
/// this discipline for the CLI/broker split.
extension PaneContentKind: ExpressibleByArgument {}
