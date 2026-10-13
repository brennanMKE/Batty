// OpenQuicklyView.swift

import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleOpenQuickly = Notification.Name("co.sstools.Batty.toggleOpenQuickly")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "OpenQuicklyView")

struct QuickOpenResult: Identifiable, Equatable {
    let sessionID: UUID
    let sessionTitle: String
    let tabID: UUID
    let tabTitle: String

    var id: UUID { tabID }
    var displayTitle: String { "\(sessionTitle) \u{203A} \(tabTitle)" }
}

enum OpenQuicklyFilter {
    /// Filters and ranks results against `query`. A result matches when the
    /// query is a subsequence of either the session title or the tab title;
    /// scoring is the max of the two so a hit in either field bubbles to the
    /// top. Empty query returns all results in their original order.
    static func apply(query: String, to results: [QuickOpenResult]) -> [QuickOpenResult] {
        guard !query.isEmpty else { return results }
        let scored: [(QuickOpenResult, Int)] = results.compactMap { result in
            let sessionScore = FuzzyMatcher.score(query, in: result.sessionTitle)
            let tabScore = FuzzyMatcher.score(query, in: result.tabTitle)
            let best = max(sessionScore, tabScore)
            return best > 0 ? (result, best) : nil
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// One ranked list of Tab rows and Project rows. Match tier decides
    /// first (3 prefix, 2 interior, 1 scattered; a path-only
    /// Project match scores 1 but sorts after every name match in that tier); between kinds in one tier Tab rows
    /// come first, because jumping to a live Tab has no side effects and
    /// opening a Project can create a Session; within a kind the given order
    /// holds. `projects` arrives in `ProjectRecency.ranked` order. A Project
    /// and a Tab never suppress each other. An empty query lists every Tab
    /// row, then every Project row.
    static func apply(
        query: String,
        tabs: [QuickOpenResult],
        projects: [OpenQuicklyProjectRow]
    ) -> [OpenQuicklyEntry] {
        guard !query.isEmpty else { return tabs.map(OpenQuicklyEntry.tab) + projects.map(OpenQuicklyEntry.project) }
        var scored: [(entry: OpenQuicklyEntry, score: Int, kind: Int, offset: Int)] = []
        for (offset, tab) in tabs.enumerated() {
            let best = max(FuzzyMatcher.score(query, in: tab.sessionTitle), FuzzyMatcher.score(query, in: tab.tabTitle))
            if best > 0 { scored.append((.tab(tab), best, 0, offset)) }
        }
        for (offset, project) in projects.enumerated() {
            let nameScore = FuzzyMatcher.score(query, in: project.name)
            if nameScore > 0 {
                scored.append((.project(project), nameScore, 1, offset))
            } else if pathMatches(query, project) {
                scored.append((.project(project), 1, 2, offset))
            }
        }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.kind != b.kind { return a.kind < b.kind }
                return a.offset < b.offset
            }
            .map(\.entry)
    }

    private static func pathMatches(_ query: String, _ project: OpenQuicklyProjectRow) -> Bool {
        [project.rootPath, project.displayPath].contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    /// The Project rows in recency order. Returns nothing, and never reads
    /// `store.projectStore`, while the Projects flag is off.
    static func projectRows(in store: AppStateStore, homeDirectory: String = NSHomeDirectory()) -> [OpenQuicklyProjectRow] {
        guard store.featureFlags.projects, let projectStore = store.projectStore else { return [] }
        let open = store.openProjectIDs
        return ProjectRecency.ranked(projectStore.projects, openProjectIDs: open).map { project in
            OpenQuicklyProjectRow(
                id: project.id,
                name: project.name,
                rootPath: project.rootPath,
                displayPath: ProjectPickerModel.abbreviate(path: project.rootPath, homeDirectory: homeDirectory),
                color: project.color,
                symbol: project.symbol,
                isOpen: open.contains(project.id)
            )
        }
    }

    /// What the sheet does with a committed row once it has closed itself:
    /// a Tab jumps, a Project action goes to the host and nothing opens here.
    static func activate(
        _ entry: OpenQuicklyEntry,
        optionHeld: Bool,
        in windowRuntime: WindowRuntime,
        onAction: ((OpenQuicklyAction) -> Void)?
    ) {
        if let action = choose(entry, optionHeld: optionHeld, in: windowRuntime) {
            onAction?(action)
        }
    }

    /// Commits a row. A Tab row jumps now and returns nil; a Project row
    /// returns the action the host runs once the sheet has closed.
    /// Option-Return on a Project opens another copy; on a Tab it is Return.
    static func choose(_ entry: OpenQuicklyEntry, optionHeld: Bool, in windowRuntime: WindowRuntime) -> OpenQuicklyAction? {
        switch entry {
        case .tab(let result):
            logger.info("open quickly jumping to session \(result.sessionTitle, privacy: .public) tab \(result.tabTitle, privacy: .public)")
            windowRuntime.jumpToTab(sessionID: result.sessionID, tabID: result.tabID)
            return nil
        case .project(let row):
            return .openProject(row.id, optionHeld ? .openNew : .focusExistingOrOpen)
        }
    }

    /// Every jumpable (session, tab) pair in `windowRuntime`, unfiltered by
    /// query — `OpenQuicklyView.allResults`'s source, extracted so it is
    /// unit-testable without instantiating the view.
    ///
    /// A non-terminal pane's `tabs` holds one structural placeholder
    /// `TabRuntime` `PaneView` never renders (`PaneRuntime.kind`'s doc
    /// comment) — surfacing it here would offer a bogus jump target (#0315
    /// review round 1, finding 3), so only `.terminal`-kind panes
    /// contribute.
    static func allResults(for windowRuntime: WindowRuntime) -> [QuickOpenResult] {
        windowRuntime.sessions.flatMap { session in
            session.tree.allPanes.filter { $0.kind == .terminal }.flatMap { pane in
                pane.tabs.map { tab in
                    QuickOpenResult(
                        sessionID: session.id,
                        sessionTitle: session.title,
                        tabID: tab.id,
                        tabTitle: TabTitleFormatter.chipTitle(for: tab)
                    )
                }
            }
        }
    }
}

/// What Open Quickly asks its host to do once the sheet has closed. Only a
/// Project open needs the sheet gone first: it may present the
/// startup-command trust sheet from the same view. A Tab jump runs at once.
enum OpenQuicklyAction: Equatable {
    case openProject(UUID, AppStateStore.ProjectOpenMode)

    func perform(
        in store: AppStateStore,
        showError: @escaping @MainActor (Error) -> Void = { NSAlert(error: $0).runModal() }
    ) {
        switch self {
        case .openProject(let id, let mode):
            ProjectOpenPresenter.open(id: id, mode: mode, in: store, showError: showError)
        }
    }
}

struct OpenQuicklyProjectRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rootPath: String
    let displayPath: String
    let color: SessionColor
    let symbol: ProjectSymbol
    let isOpen: Bool

    var hint: String { ProjectPickerModel.hint(name: name, isOpen: isOpen) }
}

enum OpenQuicklyEntry: Identifiable, Equatable {
    case tab(QuickOpenResult)
    case project(OpenQuicklyProjectRow)

    var id: String {
        switch self {
        case .tab(let result): "tab:\(result.id.uuidString)"
        case .project(let row): "project:\(row.id.uuidString)"
        }
    }
}

/// The Open Quickly sheet. It only reports a Project choice through
/// `onAction`; the host dismisses first and acts from the sheet's
/// `onDismiss`. `projectRows` and `onAction` are nil unless the Projects
/// flag is on, and it reads Projects live on every render so the OPEN
/// markers follow opens and closes while the sheet is up.
struct OpenQuicklyView: View {
    @Binding var isPresented: Bool
    let windowRuntime: WindowRuntime
    var projectRows: (() -> [OpenQuicklyProjectRow])?
    var onAction: ((OpenQuicklyAction) -> Void)?

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var allResults: [QuickOpenResult] {
        OpenQuicklyFilter.allResults(for: windowRuntime)
    }

    private var filteredEntries: [OpenQuicklyEntry] {
        OpenQuicklyFilter.apply(query: query, tabs: allResults, projects: projectRows?() ?? [])
    }

    var body: some View {
        let results = filteredEntries
        let selectedProject = selectedProjectRow(in: results)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(projectRows == nil ? "Jump to session or tab…" : "Jump to session, tab or project…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1, in: results); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1, in: results); return .handled }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        activate(results: results, optionHeld: press.modifiers.contains(.option))
                        return .handled
                    }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
                    .accessibilityIdentifier("open-quickly.filter")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(projectRows == nil ? "No sessions or tabs match your query." : "No sessions, tabs or projects match your query.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, entry in
                                row(for: entry, isSelected: idx == selectedIndex)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        activate(results: results, optionHeld: false)
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        if results.indices.contains(newIdx) {
                            withAnimation { proxy.scrollTo(results[newIdx].id, anchor: .center) }
                        }
                    }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                }
            }

            if let selectedProject {
                projectFooter(selectedProject)
            }
        }
        .frame(width: 540, height: 380)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("open-quickly.root")
        .onAppear { queryFocused = true }
    }

    @ViewBuilder
    private func row(for entry: OpenQuicklyEntry, isSelected: Bool) -> some View {
        switch entry {
        case .tab(let result):
            QuickOpenRow(result: result, isSelected: isSelected)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("open-quickly.row")
        case .project(let project):
            QuickOpenProjectRowView(row: project, isSelected: isSelected)
        }
    }

    private func projectFooter(_ project: OpenQuicklyProjectRow) -> some View {
        HStack(spacing: 18) {
            Text(project.hint)
                .fontWeight(.semibold)
                .lineLimit(1)
                .accessibilityIdentifier("open-quickly.hint")
            Spacer()
            Text("\u{2325}\u{21A9} Open another copy")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    private func selectedProjectRow(in results: [OpenQuicklyEntry]) -> OpenQuicklyProjectRow? {
        guard results.indices.contains(selectedIndex), case .project(let row) = results[selectedIndex] else { return nil }
        return row
    }

    private func moveSelection(_ delta: Int, in results: [OpenQuicklyEntry]) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activate(results: [OpenQuicklyEntry], optionHeld: Bool) {
        guard results.indices.contains(selectedIndex) else { return }
        let entry = results[selectedIndex]
        isPresented = false
        OpenQuicklyFilter.activate(entry, optionHeld: optionHeld, in: windowRuntime, onAction: onAction)
    }
}

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(result.sessionTitle)
                        .font(.body)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(result.tabTitle)
                        .font(.body)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

private struct QuickOpenProjectRowView: View {
    let row: OpenQuicklyProjectRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol.resolvedSystemName)
                .foregroundStyle(row.color.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.body)
                Text(row.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if row.isOpen {
                Text("OPEN")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                    .accessibilityIdentifier("open-quickly.open-badge.\(row.name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(row.name))
        .accessibilityValue(Text(row.isOpen ? "open" : "not open"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("open-quickly.row.project.\(row.name)")
    }
}
