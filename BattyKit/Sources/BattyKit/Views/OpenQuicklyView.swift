// OpenQuicklyView.swift

import OSLog
import SwiftUI

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "OpenQuicklyView")

extension Notification.Name {
    public static let battyOpenQuickly = Notification.Name("co.sstools.Batty.openQuickly")
}

/// One row in the Open Quickly results list. Identifies the destination
/// (session + pane + tab) and carries the matched indices for highlight
/// rendering.
struct OpenQuicklyResult: Identifiable {
    let sessionID: UUID
    let paneID: UUID
    let tabID: UUID
    let sessionTitle: String
    let tabTitle: String
    let sessionMatch: [Int]
    let tabMatch: [Int]
    let score: Double
    let recencyAnchor: Date

    var id: UUID { tabID }
}

public struct OpenQuicklyView: View {
    let store: AppStateStore
    let dismiss: () -> Void

    @State private var query: String = ""
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool

    public init(store: AppStateStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
    }

    private var results: [OpenQuicklyResult] { computeResults() }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 520, height: 360)
        .background(.thinMaterial)
        .onAppear {
            searchFocused = true
            if selectedID == nil { selectedID = results.first?.id }
        }
        .onChange(of: query) { _, _ in
            selectedID = results.first?.id
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Open Quickly", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { activateSelection() }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsList: some View {
        let rows = results
        if rows.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "rectangle.and.text.magnifyingglass",
                description: Text("Type to search session and tab names.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(rows, selection: $selectedID) { row in
                    OpenQuicklyRow(result: row)
                        .tag(row.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(row.id == selectedID ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = row.id
                            activateSelection()
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedID) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let rows = results
        guard !rows.isEmpty else { return }
        let current = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? 0
        let next = max(0, min(rows.count - 1, current + delta))
        selectedID = rows[next].id
    }

    private func activateSelection() {
        let rows = results
        guard let id = selectedID, let row = rows.first(where: { $0.id == id }) else { return }
        logger.info("activate session=\(row.sessionID, privacy: .public) tab=\(row.tabID, privacy: .public)")
        store.selectedSessionID = row.sessionID
        if let session = store.sessions.first(where: { $0.id == row.sessionID }) {
            session.tree.focusedPaneID = row.paneID
            if let pane = session.tree.allPanes.first(where: { $0.id == row.paneID }) {
                pane.activeTabID = row.tabID
                if let tab = pane.tabs.first(where: { $0.id == row.tabID }) {
                    TerminalSurfaceFocuser.focusWhenReady(terminal: tab.terminal)
                }
            }
        }
        dismiss()
    }

    private func computeResults() -> [OpenQuicklyResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var rows: [OpenQuicklyResult] = []
        let epoch = Date(timeIntervalSince1970: 0)
        for session in store.sessions {
            for pane in session.tree.allPanes {
                for (tabIndex, tab) in pane.tabs.enumerated() {
                    let tabTitle = TabTitleFormatter.chipTitle(
                        for: tab,
                        fallback: String(localized: "Tab \(tabIndex + 1)")
                    )
                    let recency = tab.lastFocusedAt ?? session.lastFocusedAt ?? epoch
                    if trimmed.isEmpty {
                        rows.append(OpenQuicklyResult(
                            sessionID: session.id,
                            paneID: pane.id,
                            tabID: tab.id,
                            sessionTitle: session.title,
                            tabTitle: tabTitle,
                            sessionMatch: [],
                            tabMatch: [],
                            score: 0,
                            recencyAnchor: recency
                        ))
                        continue
                    }
                    let sessionMatch = FuzzyMatcher.match(query: trimmed, in: session.title)
                    let tabMatch = FuzzyMatcher.match(query: trimmed, in: tabTitle)
                    let combined = "\(session.title) \(tabTitle)"
                    let combinedMatch = FuzzyMatcher.match(query: trimmed, in: combined)
                    let best = [sessionMatch?.score, tabMatch?.score, combinedMatch?.score]
                        .compactMap { $0 }
                        .max()
                    guard let bestScore = best else { continue }
                    rows.append(OpenQuicklyResult(
                        sessionID: session.id,
                        paneID: pane.id,
                        tabID: tab.id,
                        sessionTitle: session.title,
                        tabTitle: tabTitle,
                        sessionMatch: sessionMatch?.matchedIndices ?? [],
                        tabMatch: tabMatch?.matchedIndices ?? [],
                        score: bestScore,
                        recencyAnchor: recency
                    ))
                }
            }
        }
        if trimmed.isEmpty {
            rows.sort { $0.recencyAnchor > $1.recencyAnchor }
        } else {
            rows.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.recencyAnchor > rhs.recencyAnchor
            }
        }
        return rows
    }
}

private struct OpenQuicklyRow: View {
    let result: OpenQuicklyResult

    var body: some View {
        HStack(spacing: 6) {
            highlighted(result.sessionTitle, indices: result.sessionMatch)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            highlighted(result.tabTitle, indices: result.tabMatch)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private func highlighted(_ text: String, indices: [Int]) -> Text {
        let chars = Array(text)
        guard !chars.isEmpty else { return Text(text) }
        let set = Set(indices)
        var result = Text("")
        for (i, ch) in chars.enumerated() {
            let segment = Text(String(ch))
            if set.contains(i) {
                result = result + segment.fontWeight(.bold).foregroundStyle(Color.accentColor)
            } else {
                result = result + segment
            }
        }
        return result
    }
}
