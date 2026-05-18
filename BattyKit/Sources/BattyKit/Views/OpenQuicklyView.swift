// OpenQuicklyView.swift

import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleOpenQuickly = Notification.Name("co.sstools.Batty.toggleOpenQuickly")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "OpenQuicklyView")

private struct QuickOpenResult: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let sessionTitle: String
    let tabID: UUID
    let tabTitle: String

    var displayTitle: String { "\(sessionTitle) \u{203A} \(tabTitle)" }
}

struct OpenQuicklyView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var queryFocused: Bool

    private var allResults: [QuickOpenResult] {
        store.sessions.flatMap { session in
            session.tree.allPanes.flatMap { pane in
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

    private var filteredResults: [QuickOpenResult] {
        guard !query.isEmpty else { return allResults }
        return allResults
            .filter { FuzzyMatcher.matches(query, in: $0.displayTitle) }
            .sorted {
                FuzzyMatcher.score(query, in: $0.displayTitle) > FuzzyMatcher.score(query, in: $1.displayTitle)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to session or tab…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.return) { activateSelected(); return .handled }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if filteredResults.isEmpty {
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
                            ForEach(Array(filteredResults.enumerated()), id: \.element.id) { idx, result in
                                QuickOpenRow(result: result, isSelected: idx == selectedIndex)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedIndex = idx
                                        activateSelected()
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
                    }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                }
            }
        }
        .frame(width: 540, height: 380)
        .background(.regularMaterial)
        .onAppear { queryFocused = true }
    }

    private func moveSelection(_ delta: Int) {
        let count = filteredResults.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activateSelected() {
        guard filteredResults.indices.contains(selectedIndex) else { return }
        let result = filteredResults[selectedIndex]
        isPresented = false
        logger.info("open quickly jumping to session \(result.sessionTitle, privacy: .public) tab \(result.tabTitle, privacy: .public)")
        store.jumpToTab(sessionID: result.sessionID, tabID: result.tabID)
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
