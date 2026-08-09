// OpenQuicklyView.swift

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

struct OpenQuicklyView: View {
    @Binding var isPresented: Bool
    let windowRuntime: WindowRuntime

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var allResults: [QuickOpenResult] {
        OpenQuicklyFilter.allResults(for: windowRuntime)
    }

    private var filteredResults: [QuickOpenResult] {
        OpenQuicklyFilter.apply(query: query, to: allResults)
    }

    var body: some View {
        let results = filteredResults
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to session or tab…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1, in: results); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1, in: results); return .handled }
                    .onKeyPress(.return) { activate(results: results); return .handled }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No sessions or tabs match your query.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                                QuickOpenRow(result: result, isSelected: idx == selectedIndex)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        activate(results: results)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("open-quickly.row")
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
        }
        .frame(width: 540, height: 380)
        .background(.regularMaterial)
        .accessibilityIdentifier("open-quickly.root")
        .onAppear { queryFocused = true }
    }

    private func moveSelection(_ delta: Int, in results: [QuickOpenResult]) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activate(results: [QuickOpenResult]) {
        guard results.indices.contains(selectedIndex) else { return }
        let result = results[selectedIndex]
        isPresented = false
        logger.info("open quickly jumping to session \(result.sessionTitle, privacy: .public) tab \(result.tabTitle, privacy: .public)")
        windowRuntime.jumpToTab(sessionID: result.sessionID, tabID: result.tabID)
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
