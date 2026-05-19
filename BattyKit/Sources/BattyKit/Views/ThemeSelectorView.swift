// ThemeSelectorView.swift

import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleThemeSelector = Notification.Name("co.sstools.Batty.toggleThemeSelector")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ThemeSelectorView")

struct ThemeSelectorView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @State private var pinnedIDs: [String] = []
    @State private var savedThemeName: String = ""

    private var filteredPinned: [GhosttyThemeDefinition] {
        let pinned = GhosttyThemeCatalog.allThemes.filter { PinnedThemes.contains($0.name, in: pinnedIDs) }
        guard !query.isEmpty else { return pinned }
        return pinned
            .filter { FuzzyMatcher.score(query, in: $0.name) > 0 }
            .sorted { FuzzyMatcher.score(query, in: $0.name) > FuzzyMatcher.score(query, in: $1.name) }
    }

    private var filteredOthers: [GhosttyThemeDefinition] {
        let others = GhosttyThemeCatalog.allThemes.filter { !PinnedThemes.contains($0.name, in: pinnedIDs) }
        guard !query.isEmpty else { return others }
        return others
            .filter { FuzzyMatcher.score(query, in: $0.name) > 0 }
            .sorted { FuzzyMatcher.score(query, in: $0.name) > FuzzyMatcher.score(query, in: $1.name) }
    }

    private var allDisplayed: [GhosttyThemeDefinition] { filteredPinned + filteredOthers }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter themes\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.return) { confirmSelection(); return .handled }
                    .onKeyPress(.escape) { cancelSelection(); return .handled }
                Spacer()
                Text("Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if allDisplayed.isEmpty {
                ContentUnavailableView(
                    "No Themes Found",
                    systemImage: "paintpalette",
                    description: Text("Try a different search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scrollContent
            }
        }
        .frame(width: 620, height: 500)
        .background(.regularMaterial)
        .onAppear {
            savedThemeName = UserDefaults.standard.string(forKey: ThemePreference.defaultsKey) ?? ""
            pinnedIDs = PinnedThemes.load()
            searchFocused = true
        }
    }

    private var scrollContent: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredPinned.isEmpty {
                        sectionHeader("Pinned")
                        themeGrid(filteredPinned, startIndex: 0, proxy: proxy)
                    }
                    if !filteredOthers.isEmpty {
                        sectionHeader(filteredPinned.isEmpty ? "Themes" : "All Themes")
                        themeGrid(filteredOthers, startIndex: filteredPinned.count, proxy: proxy)
                    }
                }
                .padding(12)
                .onChange(of: selectedIndex) { _, newIdx in
                    if allDisplayed.indices.contains(newIdx) {
                        withAnimation { proxy.scrollTo(allDisplayed[newIdx].name, anchor: .center) }
                    }
                }
                .onChange(of: query) { _, _ in selectedIndex = 0 }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func themeGrid(_ themes: [GhosttyThemeDefinition], startIndex: Int, proxy: ScrollViewProxy) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160))], spacing: 12) {
            ForEach(Array(themes.enumerated()), id: \.element.name) { localIndex, theme in
                let globalIndex = startIndex + localIndex
                ThemeCard(
                    theme: theme,
                    isSelected: globalIndex == selectedIndex,
                    isPinned: PinnedThemes.contains(theme.name, in: pinnedIDs),
                    onTogglePin: { togglePin(theme.name) }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedIndex = globalIndex
                    applyLivePreview(theme)
                }
                .id(theme.name)
            }
        }
    }

    private func applyLivePreview(_ theme: GhosttyThemeDefinition) {
        logger.info("live preview: \(theme.name, privacy: .public)")
        store.applyThemeToAllSurfaces(theme)
    }

    private func confirmSelection() {
        guard allDisplayed.indices.contains(selectedIndex) else {
            isPresented = false
            return
        }
        let theme = allDisplayed[selectedIndex]
        UserDefaults.standard.set(theme.name, forKey: ThemePreference.defaultsKey)
        store.applyThemeToAllSurfaces(theme)
        isPresented = false
    }

    private func cancelSelection() {
        if !savedThemeName.isEmpty,
           let saved = GhosttyThemeCatalog.theme(named: savedThemeName) {
            store.applyThemeToAllSurfaces(saved)
        }
        isPresented = false
    }

    private func moveSelection(_ delta: Int) {
        let count = allDisplayed.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        applyLivePreview(allDisplayed[selectedIndex])
    }

    private func togglePin(_ name: String) {
        PinnedThemes.toggle(name, in: &pinnedIDs)
        PinnedThemes.save(pinnedIDs)
    }
}
