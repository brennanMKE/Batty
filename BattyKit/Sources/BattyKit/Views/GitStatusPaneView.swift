// GitStatusPaneView.swift

import AppKit
import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "GitStatusPaneView")

/// The Git Status view (`docs/design/git-status-view.md`) — a Mac-native
/// alternative to `git status` in a terminal: disclosure groups instead of
/// a flat list, click-to-select instead of read-only text, an inline diff
/// peek instead of a second `git diff` invocation. Read-only for this ship
/// (design §3) — every interaction here reads the repository; none mutate
/// it.
public struct GitStatusPaneView: View {
    // Plain `let`, not `@Bindable` (review round 1, D7) — nothing here
    // reads or writes through a `$content...` binding; `GitStatusPaneContent`
    // being `@Observable` is what makes this view re-render on change,
    // independent of whether the property wrapper is `@Bindable`.
    public let content: GitStatusPaneContent

    public init(content: GitStatusPaneContent) {
        self.content = content
    }

    public var body: some View {
        switch content.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notARepository(let path):
            notARepositoryView(path: path)
        case .scanFailed(let message):
            scanFailedView(message: message)
        case .snapshot(let snapshot):
            snapshotView(snapshot)
        }
    }

    // MARK: - Scan failed

    /// (Review round 1, B1's second finding.) A `git status` scan that ran
    /// but produced output that could not be decoded as UTF-8 must not
    /// silently present as "clean working tree" — this is the visible
    /// failure state that keeps that from happening.
    @ViewBuilder
    private func scanFailedView(message: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Git Status Unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Try Again") { content.refreshNow() }
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("git-status.scan-failed")
    }

    // MARK: - Not a repository

    @ViewBuilder
    private func notARepositoryView(path: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "questionmark.folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Not a Git Repository")
                .font(.title3.weight(.semibold))
            Text(path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
            Button("Change Directory…") { presentChangeDirectoryPanel() }
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("git-status.not-a-repo")
    }

    // MARK: - Snapshot

    @ViewBuilder
    private func snapshotView(_ snapshot: GitStatusSnapshot) -> some View {
        VStack(spacing: 0) {
            headerRow(snapshot)
            Divider()
            if snapshot.operationState != .none {
                operationBanner(snapshot.operationState)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !snapshot.conflicted.isEmpty {
                        fileGroup(title: "Conflicted", entries: snapshot.conflicted, staged: false)
                    }
                    fileGroup(title: "Staged Changes", entries: snapshot.staged, staged: true)
                    fileGroup(title: "Changes", entries: snapshot.unstaged, staged: false)
                    fileGroup(title: "Untracked Files", entries: snapshot.untracked, staged: false)
                    if snapshot.conflicted.isEmpty && snapshot.staged.isEmpty
                        && snapshot.unstaged.isEmpty && snapshot.untracked.isEmpty {
                        Text("Nothing to show — working tree clean.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                    worktreesGroup(snapshot.worktrees)
                }
            }
        }
        .accessibilityIdentifier("git-status.snapshot")
    }

    // MARK: - Header

    @ViewBuilder
    private func headerRow(_ snapshot: GitStatusSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerIdentity(snapshot)
                Spacer(minLength: 8)
                headerActions(showsChangeDirectoryTitle: true)
            }
            HStack(spacing: 8) {
                headerIdentity(snapshot)
                Spacer(minLength: 8)
                headerActions(showsChangeDirectoryTitle: false)
            }
            stackedHeader(snapshot)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func stackedHeader(_ snapshot: GitStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.repoName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                branchLabel(snapshot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if snapshot.hasUpstream, snapshot.ahead > 0 || snapshot.behind > 0 {
                    aheadBehindLabel(snapshot)
                        .fixedSize()
                }
                Spacer(minLength: 4)
                headerActions(showsChangeDirectoryTitle: false)
            }
            if snapshot.stashCount > 0 || snapshot.isWorktree {
                HStack(spacing: 8) {
                    if snapshot.stashCount > 0 {
                        badge("\(snapshot.stashCount) stash\(snapshot.stashCount == 1 ? "" : "es")", systemImage: "tray.full")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if snapshot.isWorktree {
                        badge("Worktree", systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            if let parent = snapshot.submoduleParentName {
                Text("Submodule of \(parent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func headerIdentity(_ snapshot: GitStatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(snapshot.repoName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize()
                branchLabel(snapshot)
                    .lineLimit(1)
                    .fixedSize()
                if snapshot.hasUpstream, snapshot.ahead > 0 || snapshot.behind > 0 {
                    aheadBehindLabel(snapshot)
                        .fixedSize()
                }
                if snapshot.stashCount > 0 {
                    badge("\(snapshot.stashCount) stash\(snapshot.stashCount == 1 ? "" : "es")", systemImage: "tray.full")
                        .lineLimit(1)
                        .fixedSize()
                }
                if snapshot.isWorktree {
                    badge("Worktree", systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let parent = snapshot.submoduleParentName {
                Text("Submodule of \(parent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func headerActions(showsChangeDirectoryTitle: Bool) -> some View {
        HStack(spacing: 8) {
            if content.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                content.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            if showsChangeDirectoryTitle {
                Button("Change Directory…") { presentChangeDirectoryPanel() }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Button {
                    presentChangeDirectoryPanel()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Change Directory…")
                .accessibilityLabel("Change Directory…")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func branchLabel(_ snapshot: GitStatusSnapshot) -> some View {
        if let branch = snapshot.branch {
            Text(branch)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text("detached HEAD @ \(snapshot.detachedSHA ?? "?")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func aheadBehindLabel(_ snapshot: GitStatusSnapshot) -> some View {
        HStack(spacing: 2) {
            if snapshot.ahead > 0 {
                Label("\(snapshot.ahead)", systemImage: "arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            if snapshot.behind > 0 {
                Label("\(snapshot.behind)", systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    // MARK: - Operation banner

    @ViewBuilder
    private func operationBanner(_ state: GitRepositoryOperationState) -> some View {
        let (text, icon): (String, String) = {
            switch state {
            case .none: return ("", "")
            case .rebase: return ("Rebase in progress", "arrow.triangle.2.circlepath")
            case .merge(let count): return ("Merge in progress — \(count) conflict\(count == 1 ? "" : "s")", "arrow.triangle.merge")
            case .cherryPick: return ("Cherry-pick in progress", "arrow.up.arrow.down")
            }
        }()
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.18))
        .accessibilityIdentifier("git-status.operation-banner")
    }

    // MARK: - File groups

    @ViewBuilder
    private func fileGroup(title: String, entries: [GitStatusFileEntry], staged: Bool) -> some View {
        if !entries.isEmpty {
            DisclosureGroup("\(title) (\(entries.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        fileRow(entry, staged: staged)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// Carries no identifier of its own: SwiftUI hands a container's identifier to
    /// the rows inside it and the rows' own `git-status.worktree.*` identifiers lose.
    @ViewBuilder
    private func worktreesGroup(_ worktrees: [GitWorktreeEntry]) -> some View {
        if worktrees.count >= 2 {
            DisclosureGroup("Worktrees (\(worktrees.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(worktrees) { worktree in
                        worktreeRow(worktree)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func worktreeSummary(_ worktree: GitWorktreeEntry) -> String {
        if worktree.isBare { return "bare" }
        if worktree.isDetached { return "detached @ \(String((worktree.headSHA ?? "").prefix(7)))" }
        return worktree.branch ?? ""
    }

    @ViewBuilder
    private func worktreeRow(_ worktree: GitWorktreeEntry) -> some View {
        let abbreviated = (worktree.path as NSString).abbreviatingWithTildeInPath
        let name = (abbreviated as NSString).lastPathComponent
        let directory = (abbreviated as NSString).deletingLastPathComponent
        let summary = worktreeSummary(worktree)
        let states = [
            worktree.isCurrent ? "current" : nil,
            worktree.isLocked ? "locked" : nil,
            worktree.isPrunable ? "prunable" : nil,
        ].compactMap { $0 }
        HStack(spacing: 6) {
            Image(systemName: worktree.isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(worktree.isCurrent ? Color.accentColor : Color.secondary)
            HStack(spacing: 4) {
                Text(name)
                    .fontWeight(.medium)
                if !directory.isEmpty {
                    Text(directory)
                        .foregroundStyle(.secondary)
                }
                if !worktree.isBare, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
            if worktree.isBare { badge("Bare", systemImage: "archivebox") }
            if worktree.isLocked {
                if let reason = worktree.lockReason {
                    badge("Locked", systemImage: "lock").help(reason)
                } else {
                    badge("Locked", systemImage: "lock")
                }
            }
            if worktree.isPrunable {
                if let reason = worktree.pruneReason {
                    badge("Prunable", systemImage: "trash").help(reason)
                } else {
                    badge("Prunable", systemImage: "trash")
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
            }
            .disabled(worktree.isPrunable && !FileManager.default.fileExists(atPath: worktree.path))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["\(abbreviated), \(summary)"] + states).joined(separator: ", "))
        .accessibilityIdentifier("git-status.worktree.\((worktree.path as NSString).lastPathComponent)")
    }

    @ViewBuilder
    private func fileRow(_ entry: GitStatusFileEntry, staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(entry.statusKind.badge)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(color(for: entry.statusKind.tone))
                    .frame(minWidth: 18)
                pathLabel(entry)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                content.selectEntry(entry, staged: staged)
            }
            .contextMenu {
                fileContextMenu(entry)
            }
            .accessibilityIdentifier("git-status.file.\(entry.path)")

            if content.selectedEntryID == entry.id {
                diffPeek()
            }
        }
    }

    @ViewBuilder
    private func pathLabel(_ entry: GitStatusFileEntry) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        let directory = (entry.path as NSString).deletingLastPathComponent
        HStack(spacing: 4) {
            if let origPath = entry.origPath {
                Text(origPath)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .fontWeight(.medium)
            if !directory.isEmpty {
                Text(directory)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func color(for tone: GitFileStatusKind.SemanticTone) -> Color {
        switch tone {
        case .positive: return .green
        case .caution: return .orange
        case .negative: return .red
        case .neutral: return .secondary
        }
    }

    /// (Review round 1, D2.) Caps the diff peek's rendered line count so a
    /// huge diff doesn't build a correspondingly deep `Text` concatenation
    /// on the main actor — each `+` in `partial = partial + ... + Text("\n")`
    /// below is itself an allocation, so an uncapped 50k-line diff was
    /// 50k of them.
    private static let diffPeekMaxLines = 2000

    @ViewBuilder
    private func diffPeek() -> some View {
        Group {
            if content.isDiffLoading {
                ProgressView()
                    .padding(8)
            } else if let diffText = content.diffText, !diffText.isEmpty {
                let allLines = diffText.split(separator: "\n", omittingEmptySubsequences: false)
                let shownLines = allLines.prefix(Self.diffPeekMaxLines)
                let wasTruncated = allLines.count > Self.diffPeekMaxLines
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        shownLines
                            .reduce(into: Text("")) { partial, line in
                                partial = partial + diffLine(String(line)) + Text("\n")
                            }
                            .font(.system(.caption, design: .monospaced))
                        if wasTruncated {
                            Text("Diff truncated — showing first \(Self.diffPeekMaxLines) of \(allLines.count) lines.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(8)
                }
            } else {
                Text("No diff available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .accessibilityIdentifier("git-status.diff-peek")
    }

    private func diffLine(_ line: String) -> Text {
        if line.hasPrefix("+") {
            return Text(line).foregroundStyle(.green)
        } else if line.hasPrefix("-") {
            return Text(line).foregroundStyle(.red)
        }
        return Text(line).foregroundStyle(.primary)
    }

    /// `entry.path` is always relative to the repository toplevel, per
    /// `git status --porcelain=v2`'s own contract — regardless of what
    /// directory `git` was invoked in (review round 3, R1). Building these
    /// URLs from `content.directoryPath` (which can be a subdirectory of
    /// the repo) silently doubled the subdirectory into the path and
    /// pointed at a file that doesn't exist.
    private func absoluteFileURL(for entry: GitStatusFileEntry) -> URL {
        URL(fileURLWithPath: content.repositoryToplevelOrDirectoryPath).appendingPathComponent(entry.path)
    }

    @ViewBuilder
    private func fileContextMenu(_ entry: GitStatusFileEntry) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([absoluteFileURL(for: entry)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(absoluteFileURL(for: entry).path, forType: .string)
        }
        Button("Open in Default Editor") {
            NSWorkspace.shared.open(absoluteFileURL(for: entry))
        }
    }

    // MARK: - Change Directory…

    private func presentChangeDirectoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: content.directoryPath)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            logger.info("change-directory: \(url.path, privacy: .private)")
            content.changeDirectory(to: url.path)
        }
    }
}
