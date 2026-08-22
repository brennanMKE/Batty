// GitStatusModel.swift

import Foundation

/// Two-letter/one-letter status kind for a single file entry, following
/// `git status --porcelain=v2`'s own X/Y status letters
/// (`docs/design/git-status-view.md` §2, §4). Pure value type — no I/O, no
/// view types — so `GitStatusPorcelainParser` is testable without a
/// subprocess or a filesystem.
public nonisolated enum GitFileStatusKind: String, Sendable, Equatable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case unmerged
    case untracked

    /// Matches the design's badge convention: `M`/`A`/`D`/`R`/`C`, `U` for
    /// unmerged, `??` for untracked.
    public var badge: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .unmerged: return "U"
        case .untracked: return "??"
        }
    }

    /// `docs/design/git-status-view.md` §2: "green for added/staged,
    /// orange/yellow for modified, red for deleted/unmerged, gray for
    /// untracked." Named semantically here (not `Color`, which would pull
    /// SwiftUI into a Model-layer file) — the view maps these to
    /// `ChromePalette`-appropriate colors.
    public enum SemanticTone: Sendable, Equatable {
        case positive, caution, negative, neutral
    }

    public var tone: SemanticTone {
        switch self {
        case .added: return .positive
        case .modified, .renamed, .copied: return .caution
        case .deleted, .unmerged: return .negative
        case .untracked: return .neutral
        }
    }
}

/// A single file's status line within one group (conflicted/staged/
/// unstaged/untracked). `origPath` is set only for a rename/copy entry.
public nonisolated struct GitStatusFileEntry: Sendable, Equatable, Identifiable, Hashable {
    public let path: String
    public let origPath: String?
    public let statusKind: GitFileStatusKind

    public init(path: String, origPath: String? = nil, statusKind: GitFileStatusKind) {
        self.path = path
        self.origPath = origPath
        self.statusKind = statusKind
    }

    /// Stable across a re-scan producing an equal entry (path + origin +
    /// kind) so SwiftUI's `ForEach`/selection identity doesn't thrash on
    /// every refresh tick.
    public var id: String {
        if let origPath {
            return "\(statusKind.rawValue):\(origPath)->\(path)"
        }
        return "\(statusKind.rawValue):\(path)"
    }
}

/// What `.git` marker files say about an in-progress operation, detected by
/// `GitStatusScanning` (existence checks only — see
/// `docs/design/git-status-view.md` §4's ".git churn during a rebase").
/// Deliberately does not carry a conflict count — that count comes from the
/// same porcelain scan's `u` (unmerged) lines, composed by
/// `GitStatusPaneContent` into `GitRepositoryOperationState.merge(conflictCount:)`.
public nonisolated enum GitOperationMarker: Sendable, Equatable {
    case none
    case rebase
    case merge
    case cherryPick
}

/// The state banner's content (`docs/design/git-status-view.md` §2.2).
public nonisolated enum GitRepositoryOperationState: Sendable, Equatable {
    case none
    case rebase
    case merge(conflictCount: Int)
    case cherryPick
}

/// One fully-parsed and composed scan result — everything the header, state
/// banner, and grouped file lists need to render (`docs/design/git-status-view.md`
/// §2). `updatedAt` is excluded from `Equatable` comparisons a caller cares
/// about content-equality for (there is no dedicated `contentEquals`
/// override here; callers that need "did anything visible change" compare
/// the other fields directly, matching this type's plain field-by-field
/// `Equatable`).
public nonisolated struct GitStatusSnapshot: Sendable, Equatable {
    public var repoName: String
    /// The repository's working-tree root (`git rev-parse --show-toplevel`)
    /// — the base every path in `conflicted`/`staged`/`unstaged`/`untracked`
    /// is relative to, per `git status --porcelain=v2`'s own contract
    /// (paths are always toplevel-relative, regardless of what directory
    /// `git` was invoked in). Review round 3, R1: this is *not*
    /// necessarily the same directory `GitStatusPaneContent.directoryPath`
    /// resolved to — a pane targeting a subdirectory of a repo has a
    /// `directoryPath` below this root.
    public var repositoryToplevel: String
    public var branch: String?
    public var detachedSHA: String?
    public var ahead: Int
    public var behind: Int
    public var hasUpstream: Bool
    public var stashCount: Int
    public var submoduleParentName: String?
    public var isWorktree: Bool
    public var operationState: GitRepositoryOperationState
    public var conflicted: [GitStatusFileEntry]
    public var staged: [GitStatusFileEntry]
    public var unstaged: [GitStatusFileEntry]
    public var untracked: [GitStatusFileEntry]
    public var updatedAt: Date

    public init(
        repoName: String,
        repositoryToplevel: String,
        branch: String? = nil,
        detachedSHA: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        hasUpstream: Bool = false,
        stashCount: Int = 0,
        submoduleParentName: String? = nil,
        isWorktree: Bool = false,
        operationState: GitRepositoryOperationState = .none,
        conflicted: [GitStatusFileEntry] = [],
        staged: [GitStatusFileEntry] = [],
        unstaged: [GitStatusFileEntry] = [],
        untracked: [GitStatusFileEntry] = [],
        updatedAt: Date = Date()
    ) {
        self.repoName = repoName
        self.repositoryToplevel = repositoryToplevel
        self.branch = branch
        self.detachedSHA = detachedSHA
        self.ahead = ahead
        self.behind = behind
        self.hasUpstream = hasUpstream
        self.stashCount = stashCount
        self.submoduleParentName = submoduleParentName
        self.isWorktree = isWorktree
        self.operationState = operationState
        self.conflicted = conflicted
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.updatedAt = updatedAt
    }
}

/// What `GitStatusPaneContent` shows: either it hasn't scanned yet, the
/// resolved directory isn't a git repository (`docs/design/git-status-view.md`
/// §1's defined empty state), a scan that ran but whose output could not be
/// trusted (review round 1, B1 — e.g. `git status`'s stdout was not valid
/// UTF-8, which must surface as a visible failure rather than silently
/// rendering as a clean working tree), or a real snapshot.
public nonisolated enum GitStatusPaneState: Sendable, Equatable {
    case loading
    case notARepository(path: String)
    case snapshot(GitStatusSnapshot)
    case scanFailed(String)
}

/// Pure parser for `git --no-optional-locks status --porcelain=v2 --branch
/// --show-stash -z` output (`docs/design/git-status-view.md` §4). No I/O, no
/// subprocess — the subprocess call lives in `GitStatusScanning`; this type
/// only turns its stdout into structured data, so it's testable against
/// fixed string fixtures without spawning `git` (`GitStatusPorcelainParserTests`).
///
/// **`-z` is load-bearing, not cosmetic (review round 1, B1).** Without
/// `-z`, porcelain v2 C-quotes any "unusual" path — always for control
/// characters, and under the (default) `core.quotePath=true` for every byte
/// ≥ 0x80, i.e. any non-ASCII filename. An earlier version of this parser
/// ran the command without `-z` and took every path field literally, so a
/// file named `café.txt` rendered as the literal escaped text
/// `"caf\303\251.txt"` — quotes, backslashes, and all — which then broke
/// every downstream consumer of that string (`git diff -- <path>` matches
/// nothing against the mangled name; Reveal in Finder/Copy Path/Open in
/// Default Editor all resolve to a path that doesn't exist). `-z` disables
/// that quoting entirely per git's own documentation and switches every
/// record's terminator from `\n` to `\0` (including the rename/copy
/// record's `path`/`origPath` pair, which becomes **two separate
/// NUL-terminated tokens** instead of one token with an embedded tab) —
/// this is git's own documented recommendation for machine consumption,
/// and it removes the whole class of mis-decoding rather than papering
/// over one instance of it.
///
/// Field layout verified directly against real `git status --porcelain=v2
/// -z` output (git 2.50.1, via `od -c`) while writing this parser, for
/// plain-ASCII paths, a real (not literal-backslash) non-ASCII path, a path
/// containing a space, and a path containing a literal `"` — every one of
/// which appears as raw, unescaped bytes under `-z`, confirming there is no
/// per-field unescaping left to do once `-z` is in play.
public nonisolated enum GitStatusPorcelainParser {
    public nonisolated struct Result: Sendable, Equatable {
        public var branch: String?
        public var isDetached: Bool
        public var oid: String?
        public var ahead: Int
        public var behind: Int
        public var hasUpstream: Bool
        public var stashCount: Int
        public var conflicted: [GitStatusFileEntry]
        public var staged: [GitStatusFileEntry]
        public var unstaged: [GitStatusFileEntry]
        public var untracked: [GitStatusFileEntry]

        public init(
            branch: String? = nil,
            isDetached: Bool = false,
            oid: String? = nil,
            ahead: Int = 0,
            behind: Int = 0,
            hasUpstream: Bool = false,
            stashCount: Int = 0,
            conflicted: [GitStatusFileEntry] = [],
            staged: [GitStatusFileEntry] = [],
            unstaged: [GitStatusFileEntry] = [],
            untracked: [GitStatusFileEntry] = []
        ) {
            self.branch = branch
            self.isDetached = isDetached
            self.oid = oid
            self.ahead = ahead
            self.behind = behind
            self.hasUpstream = hasUpstream
            self.stashCount = stashCount
            self.conflicted = conflicted
            self.staged = staged
            self.unstaged = unstaged
            self.untracked = untracked
        }
    }

    /// `output` is `-z`-terminated: every record (including header lines)
    /// ends at a NUL byte, not a newline. A rename/copy record is **two**
    /// consecutive NUL-terminated tokens — the `2 ...` record ending at
    /// `path`, immediately followed by a second token that is `origPath`
    /// alone — so this loop advances by two tokens when it consumes one.
    public static func parse(_ output: String) -> Result {
        var result = Result()
        let tokens = output.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("# branch.oid ") {
                result.oid = String(token.dropFirst("# branch.oid ".count))
            } else if token.hasPrefix("# branch.head ") {
                let value = String(token.dropFirst("# branch.head ".count))
                if value == "(detached)" {
                    result.isDetached = true
                } else {
                    result.branch = value
                }
            } else if token.hasPrefix("# branch.upstream ") {
                result.hasUpstream = true
            } else if token.hasPrefix("# branch.ab ") {
                let rest = token.dropFirst("# branch.ab ".count)
                for part in rest.split(separator: " ") {
                    if part.hasPrefix("+"), let value = Int(part.dropFirst()) {
                        result.ahead = value
                    } else if part.hasPrefix("-"), let value = Int(part.dropFirst()) {
                        result.behind = value
                    }
                }
            } else if token.hasPrefix("# stash ") {
                result.stashCount = Int(token.dropFirst("# stash ".count)) ?? 0
            } else if token.hasPrefix("#") {
                // Unrecognized header (e.g. `# branch.oid (initial)` is
                // handled above by the `branch.oid` prefix itself — this
                // branch is for any *other* `#`-prefixed line, not a case
                // observed in practice but harmless to skip).
            } else if token.hasPrefix("1 ") {
                appendOrdinary(token, into: &result)
            } else if token.hasPrefix("2 ") {
                let origPath = index + 1 < tokens.count ? tokens[index + 1] : ""
                appendRename(token, origPath: origPath, into: &result)
                index += 1 // consume the origPath token too
            } else if token.hasPrefix("u ") {
                appendUnmerged(token, into: &result)
            } else if token.hasPrefix("? ") {
                result.untracked.append(GitStatusFileEntry(path: String(token.dropFirst(2)), statusKind: .untracked))
            }
            // "!" (ignored) entries only appear with `--ignored`, not
            // requested here — nothing to handle.
            index += 1
        }

        return result
    }

    /// Splits `token` into exactly `count` space-separated fields, where
    /// the last field is "everything remaining" (so a path containing
    /// spaces is never itself split further — under `-z` a space inside a
    /// path is a literal, unescaped byte, no different from any other).
    /// Returns `nil` if fewer than `count - 1` spaces are found before the
    /// final field.
    private static func splitFields(_ token: String, count: Int) -> [String]? {
        guard count > 0 else { return nil }
        var remainder = Substring(token)
        var fields: [String] = []
        for _ in 0..<(count - 1) {
            guard let spaceIndex = remainder.firstIndex(of: " ") else { return nil }
            fields.append(String(remainder[remainder.startIndex..<spaceIndex]))
            remainder = remainder[remainder.index(after: spaceIndex)...]
        }
        fields.append(String(remainder))
        return fields
    }

    /// Ordinary changed entry: `1 XY sub mH mI mW hH hI path` (9 fields).
    private static func appendOrdinary(_ token: String, into result: inout Result) {
        guard let fields = splitFields(token, count: 9) else { return }
        let xy = Array(fields[1])
        guard xy.count == 2 else { return }
        let path = fields[8]
        if let kind = statusKind(for: xy[0]) {
            result.staged.append(GitStatusFileEntry(path: path, statusKind: kind))
        }
        if let kind = statusKind(for: xy[1]) {
            result.unstaged.append(GitStatusFileEntry(path: path, statusKind: kind))
        }
    }

    /// Renamed/copied entry: `2 XY sub mH mI mW hH hI X<score> path` (10
    /// fields, `path` is the 10th) — `origPath` is a **separate** token
    /// under `-z`, passed in by the caller rather than embedded here.
    private static func appendRename(_ token: String, origPath: String, into result: inout Result) {
        guard let fields = splitFields(token, count: 10) else { return }
        let xy = Array(fields[1])
        guard xy.count == 2 else { return }
        let path = fields[9]
        if let kind = statusKind(for: xy[0]) {
            result.staged.append(GitStatusFileEntry(path: path, origPath: origPath, statusKind: kind))
        }
        if let kind = statusKind(for: xy[1]) {
            result.unstaged.append(GitStatusFileEntry(path: path, origPath: origPath, statusKind: kind))
        }
    }

    /// Unmerged entry: `u XY sub m1 m2 m3 mW h1 h2 h3 path` (11 fields).
    private static func appendUnmerged(_ token: String, into result: inout Result) {
        guard let fields = splitFields(token, count: 11) else { return }
        let path = fields[10]
        result.conflicted.append(GitStatusFileEntry(path: path, statusKind: .unmerged))
    }

    private static func statusKind(for code: Character) -> GitFileStatusKind? {
        switch code {
        case "A": return .added
        case "M", "T": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unmerged
        default: return nil
        }
    }
}
