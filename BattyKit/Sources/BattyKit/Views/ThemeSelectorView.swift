// ThemeSelectorView.swift

import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    public static let battyToggleThemeSelector = Notification.Name("co.sstools.Batty.toggleThemeSelector")
}

nonisolated private let logger = Logger(subsystem: Logging.subsystem, category: "ThemeSelectorView")

/// The Theme display order used at presentation, before any filter query is
/// applied — pinned Themes (catalog order) followed by the rest (catalog
/// order). Matches `filteredPinned + filteredOthers` in both selectors below
/// when `query` is empty, which it always is at presentation. Pulled out as
/// a standalone function (rather than an instance computed property) so the
/// keyboard cursor's initial index can be derived inside `init`, before
/// `pinnedIDs` exists as instance state to back a property read (`#0363`).
/// `internal`, not `private`, so `BattyKitTests` can exercise it directly.
func themeDisplayOrder(pinnedIDs: [String]) -> [GhosttyThemeDefinition] {
    let pinned = BattyThemeCatalog.allThemes.filter { PinnedThemes.contains($0.name, in: pinnedIDs) }
    let others = BattyThemeCatalog.allThemes.filter { !PinnedThemes.contains($0.name, in: pinnedIDs) }
    return pinned + others
}

/// The keyboard-cursor index for `activeThemeName` within
/// `themeDisplayOrder(pinnedIDs:)`, or `0` when there is no active Theme, or
/// it isn't present in the catalog order — which shouldn't happen (the
/// catalog is the only source both selectors read from) but degrades to the
/// pre-`#0363` default rather than crashing.
func themeCursorIndex(activeThemeName: String?, pinnedIDs: [String]) -> Int {
    guard let activeThemeName else { return 0 }
    let order = themeDisplayOrder(pinnedIDs: pinnedIDs)
    return order.firstIndex(where: { $0.name == activeThemeName }) ?? 0
}

/// Scroll id carried by the first section header of the visible list. A
/// filter change scrolls here, not to the first card, so the header stays in
/// view; the header always sits directly above the first element of the
/// current filtered list, whichever section (Pinned or Themes) that is.
let themeListTopID = "co.sstools.Batty.themeListTop"

/// The scroll target after a filter change: the top of the list, or `nil`
/// when nothing is displayed (the empty state replaces the scroll view).
func themeFilterScrollTarget(displayed: [GhosttyThemeDefinition]) -> String? {
    displayed.isEmpty ? nil : themeListTopID
}

enum ThemeListSection: Equatable { case pinned, others }

/// The section whose header carries `themeListTopID`: the first non-empty one.
func themeTopHeaderSection(pinnedCount: Int, othersCount: Int) -> ThemeListSection? {
    if pinnedCount > 0 { return .pinned }
    return othersCount > 0 ? .others : nil
}

struct ThemeSelectorView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore

    @State private var query = ""
    /// Keyboard-cursor position — seeded onto the active Theme in `init` so
    /// `Down` steps past it rather than an arbitrary catalog entry, and
    /// `Return` on open re-selects the Theme already in effect (`#0363`).
    @State private var cursorIndex: Int
    @FocusState private var searchFocused: Bool
    /// Loaded in `init`, not `.onAppear`, because `themeDisplayOrder` (used
    /// to seed `cursorIndex` above) depends on pinning order, and `onAppear`
    /// runs too late to affect the initial-state seeding (`#0363`).
    /// `PinnedThemes.load()` is a pure `UserDefaults` read, so this is safe.
    @State private var pinnedIDs: [String]
    /// The global Theme for the current appearance
    /// (`ThemePreference.activeTheme()`). This is a `let`, but it is not a
    /// frozen snapshot: SwiftUI re-initializes this view struct on every
    /// body re-run of the presenting view, which happens constantly while
    /// this sheet is open (both presenters read `themeChrome`, and every
    /// applied Theme calls `themeChrome.update(from:)`), so this property
    /// is re-read from `UserDefaults` on every one of those re-inits. It
    /// *looks* stable while the user arrows around only because
    /// `moveSelection` previews via `applyThemeToAllSurfaces`, which never
    /// writes the preference — the value this reads simply hasn't moved.
    /// Clicking a card calls `selectTheme`, which does write the
    /// preference, so the very next re-init picks up the new value and the
    /// mark hops there. Net effect: **the outline marks the committed
    /// Theme; the cursor badge (`isCursor`) marks the live preview.**
    /// Distinct from `cursorIndex`, which tracks keyboard navigation and
    /// can end up on a different card than either. `nil` when no Theme is
    /// currently active; the mark then simply doesn't render (`#0363`).
    private let activeThemeName: String?

    init(isPresented: Binding<Bool>, store: AppStateStore) {
        self._isPresented = isPresented
        self.store = store

        let pinned = PinnedThemes.load()
        self._pinnedIDs = State(initialValue: pinned)

        // `activeTheme()` routes through `migrateAndSeedIfNeeded`, which
        // writes UserDefaults keys that `@AppStorage` observers watch
        // (BattyCommands.swift:22-23, SettingsView.swift:120-121) — an
        // observed-state write during view construction, which the
        // observation rules forbid. It can't actually fire here:
        // `AppStateStore.swift:593` already calls `activeTheme()` during
        // store construction, long before any `RootWindowView` (and so
        // this sheet) exists, so the migration flag is always already set
        // by the time this init runs. That's an undocumented launch-order
        // guarantee this call site relies on, not something it enforces.
        let active = ThemePreference.activeTheme()
        self.activeThemeName = active?.name
        self._cursorIndex = State(initialValue: themeCursorIndex(activeThemeName: active?.name, pinnedIDs: pinned))
    }

    private var filteredPinned: [GhosttyThemeDefinition] {
        let pinned = BattyThemeCatalog.allThemes.filter { PinnedThemes.contains($0.name, in: pinnedIDs) }
        guard !query.isEmpty else { return pinned }
        return pinned
            .filter { FuzzyMatcher.score(query, in: $0.name) > 0 }
            .sorted { FuzzyMatcher.score(query, in: $0.name) > FuzzyMatcher.score(query, in: $1.name) }
    }

    private var filteredOthers: [GhosttyThemeDefinition] {
        let others = BattyThemeCatalog.allThemes.filter { !PinnedThemes.contains($0.name, in: pinnedIDs) }
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
                    .accessibilityIdentifier("theme-selector.filter")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme-selector.root")
        .onAppear {
            searchFocused = true
        }
    }

    private var scrollContent: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredPinned.isEmpty {
                        sectionHeader("Pinned", isTop: themeTopHeaderSection(pinnedCount: filteredPinned.count, othersCount: filteredOthers.count) == .pinned)
                        themeGrid(filteredPinned, startIndex: 0, proxy: proxy)
                    }
                    if !filteredOthers.isEmpty {
                        sectionHeader(filteredPinned.isEmpty ? "Themes" : "All Themes", isTop: themeTopHeaderSection(pinnedCount: filteredPinned.count, othersCount: filteredOthers.count) == .others)
                        themeGrid(filteredOthers, startIndex: filteredPinned.count, proxy: proxy)
                    }
                }
                .padding(12)
                .onAppear {
                    // Initial positioning only — deliberately not wrapped in
                    // `withAnimation`. An animated scroll to a target that's
                    // already visible (the common case: a pinned active
                    // Theme lands in the first section) reads as a jarring
                    // twitch; an unanimated `scrollTo` is either an
                    // imperceptible no-op or a silent jump straight to the
                    // right place. Attached to the `ScrollViewReader`'s
                    // content, not the sheet's root `onAppear`, so it runs
                    // after this LazyVStack/LazyVGrid pair has had a layout
                    // pass — calling `scrollTo` before that can silently
                    // no-op in a lazy container (`#0363`).
                    scrollToActiveIfNeeded(proxy: proxy)
                }
                .onChange(of: cursorIndex) { _, newIdx in
                    if allDisplayed.indices.contains(newIdx) {
                        withAnimation { proxy.scrollTo(allDisplayed[newIdx].name, anchor: .center) }
                    }
                }
                .onChange(of: query) { _, _ in
                    // Event-origin (a keystroke flips `query`), so the
                    // `cursorIndex` write is routine. Unanimated: an
                    // animated swoop from deep in the catalog on every
                    // keystroke would be worse than the bug. The cursor
                    // reset alone can't scroll — it is usually already 0,
                    // so `onChange(of: cursorIndex)` doesn't fire (`#0394`).
                    cursorIndex = 0
                    if let target = themeFilterScrollTarget(displayed: allDisplayed) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private func scrollToActiveIfNeeded(proxy: ScrollViewProxy) {
        guard let activeThemeName, allDisplayed.contains(where: { $0.name == activeThemeName }) else { return }
        proxy.scrollTo(activeThemeName, anchor: .center)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, isTop: Bool) -> some View {
        let header = Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        if isTop {
            header.id(themeListTopID)
        } else {
            header
        }
    }

    @ViewBuilder
    private func themeGrid(_ themes: [GhosttyThemeDefinition], startIndex: Int, proxy: ScrollViewProxy) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160))], spacing: 12) {
            ForEach(Array(themes.enumerated()), id: \.element.name) { localIndex, theme in
                let globalIndex = startIndex + localIndex
                ThemeCard(
                    theme: theme,
                    isActive: theme.name == activeThemeName,
                    isCursor: globalIndex == cursorIndex,
                    isPinned: PinnedThemes.contains(theme.name, in: pinnedIDs),
                    onTogglePin: { togglePin(theme.name) }
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    cursorIndex = globalIndex
                    selectTheme(theme)
                    isPresented = false
                }
                .onTapGesture {
                    cursorIndex = globalIndex
                    selectTheme(theme)
                }
                .id(theme.name)
            }
        }
    }

    private func selectTheme(_ theme: GhosttyThemeDefinition) {
        let isDark = NSApp.effectiveAppearance.isDark
        logger.info("selected theme: \(theme.name, privacy: .public) isDark=\(isDark, privacy: .public)")
        let key = ThemePreference.defaultsKey(isDark: isDark)
        UserDefaults.standard.set(theme.name, forKey: key)
        store.applyThemeToAllSurfaces(theme)
    }

    private func confirmSelection() {
        guard allDisplayed.indices.contains(cursorIndex) else {
            isPresented = false
            return
        }
        selectTheme(allDisplayed[cursorIndex])
        isPresented = false
    }

    private func cancelSelection() {
        isPresented = false
    }

    private func moveSelection(_ delta: Int) {
        let count = allDisplayed.count
        guard count > 0 else { return }
        cursorIndex = (cursorIndex + delta + count) % count
        store.applyThemeToAllSurfaces(allDisplayed[cursorIndex])
    }

    private func togglePin(_ name: String) {
        PinnedThemes.toggle(name, in: &pinnedIDs)
        PinnedThemes.save(pinnedIDs)
    }
}

/// A theme picker scoped to a single session. Selecting a theme sets
/// `session.localThemeName` without touching the global `ThemePreference`.
/// Cancelling restores whichever theme was active before the picker opened.
struct SessionThemeSelectorView: View {
    @Binding var isPresented: Bool
    let store: AppStateStore
    @Bindable var session: SessionRuntime

    @State private var query = ""
    /// See `ThemeSelectorView.cursorIndex` — same seeding rationale.
    @State private var cursorIndex: Int
    @FocusState private var searchFocused: Bool
    /// See `ThemeSelectorView.pinnedIDs` — loaded in `init`, not `.onAppear`.
    @State private var pinnedIDs: [String]
    /// The Session's *effective* Theme: `session.localThemeName` if set,
    /// else the global Theme for the current appearance
    /// (`ThemePreference.effectiveTheme`). Deliberately not just
    /// `session.localThemeName` — a Session with no override still has an
    /// effective Theme (the global one), which is the default state for
    /// every Session on every launch, and must be markable too. Like
    /// `ThemeSelectorView.activeThemeName`, this `let` is re-read on every
    /// re-init of this view struct rather than frozen at presentation; it
    /// holds steady while arrow-key previewing (`applyTheme(_:to:)` never
    /// writes `localThemeName` or the global preference) and only moves
    /// when a click commits a new choice via `selectTheme` — outline marks
    /// committed, cursor badge marks preview (`#0363`).
    private let activeThemeName: String?

    init(isPresented: Binding<Bool>, store: AppStateStore, session: SessionRuntime) {
        self._isPresented = isPresented
        self.store = store
        self._session = Bindable(wrappedValue: session)

        let pinned = PinnedThemes.load()
        self._pinnedIDs = State(initialValue: pinned)

        let isDark = NSApp?.effectiveAppearance.isDark ?? true
        let active = ThemePreference.effectiveTheme(localThemeName: session.localThemeName, isDark: isDark)
        self.activeThemeName = active?.name
        self._cursorIndex = State(initialValue: themeCursorIndex(activeThemeName: active?.name, pinnedIDs: pinned))
    }

    private var filteredPinned: [GhosttyThemeDefinition] {
        let pinned = BattyThemeCatalog.allThemes.filter { PinnedThemes.contains($0.name, in: pinnedIDs) }
        guard !query.isEmpty else { return pinned }
        return pinned
            .filter { FuzzyMatcher.score(query, in: $0.name) > 0 }
            .sorted { FuzzyMatcher.score(query, in: $0.name) > FuzzyMatcher.score(query, in: $1.name) }
    }

    private var filteredOthers: [GhosttyThemeDefinition] {
        let others = BattyThemeCatalog.allThemes.filter { !PinnedThemes.contains($0.name, in: pinnedIDs) }
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
                    .accessibilityIdentifier("theme-selector.filter")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme-selector.root")
        .onAppear {
            searchFocused = true
        }
    }

    private var scrollContent: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredPinned.isEmpty {
                        sectionHeader("Pinned", isTop: themeTopHeaderSection(pinnedCount: filteredPinned.count, othersCount: filteredOthers.count) == .pinned)
                        themeGrid(filteredPinned, startIndex: 0, proxy: proxy)
                    }
                    if !filteredOthers.isEmpty {
                        sectionHeader(filteredPinned.isEmpty ? "Themes" : "All Themes", isTop: themeTopHeaderSection(pinnedCount: filteredPinned.count, othersCount: filteredOthers.count) == .others)
                        themeGrid(filteredOthers, startIndex: filteredPinned.count, proxy: proxy)
                    }
                }
                .padding(12)
                .onAppear {
                    // See `ThemeSelectorView.scrollContent` — same
                    // no-animation, post-layout rationale (`#0363`).
                    scrollToActiveIfNeeded(proxy: proxy)
                }
                .onChange(of: cursorIndex) { _, newIdx in
                    if allDisplayed.indices.contains(newIdx) {
                        withAnimation { proxy.scrollTo(allDisplayed[newIdx].name, anchor: .center) }
                    }
                }
                .onChange(of: query) { _, _ in
                    // Event-origin (a keystroke flips `query`), so the
                    // `cursorIndex` write is routine. Unanimated: an
                    // animated swoop from deep in the catalog on every
                    // keystroke would be worse than the bug. The cursor
                    // reset alone can't scroll — it is usually already 0,
                    // so `onChange(of: cursorIndex)` doesn't fire (`#0394`).
                    cursorIndex = 0
                    if let target = themeFilterScrollTarget(displayed: allDisplayed) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private func scrollToActiveIfNeeded(proxy: ScrollViewProxy) {
        guard let activeThemeName, allDisplayed.contains(where: { $0.name == activeThemeName }) else { return }
        proxy.scrollTo(activeThemeName, anchor: .center)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, isTop: Bool) -> some View {
        let header = Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        if isTop {
            header.id(themeListTopID)
        } else {
            header
        }
    }

    @ViewBuilder
    private func themeGrid(_ themes: [GhosttyThemeDefinition], startIndex: Int, proxy: ScrollViewProxy) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160))], spacing: 12) {
            ForEach(Array(themes.enumerated()), id: \.element.name) { localIndex, theme in
                let globalIndex = startIndex + localIndex
                ThemeCard(
                    theme: theme,
                    isActive: theme.name == activeThemeName,
                    isCursor: globalIndex == cursorIndex,
                    isPinned: PinnedThemes.contains(theme.name, in: pinnedIDs),
                    onTogglePin: { togglePin(theme.name) }
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    cursorIndex = globalIndex
                    selectTheme(theme)
                    isPresented = false
                }
                .onTapGesture {
                    cursorIndex = globalIndex
                    selectTheme(theme)
                }
                .id(theme.name)
            }
        }
    }

    private func selectTheme(_ theme: GhosttyThemeDefinition) {
        session.localThemeName = theme.name
        store.applyTheme(theme, to: session)
    }

    private func confirmSelection() {
        guard allDisplayed.indices.contains(cursorIndex) else {
            isPresented = false
            return
        }
        selectTheme(allDisplayed[cursorIndex])
        isPresented = false
    }

    private func cancelSelection() {
        isPresented = false
    }

    private func moveSelection(_ delta: Int) {
        let count = allDisplayed.count
        guard count > 0 else { return }
        cursorIndex = (cursorIndex + delta + count) % count
        store.applyTheme(allDisplayed[cursorIndex], to: session)
    }

    private func togglePin(_ name: String) {
        PinnedThemes.toggle(name, in: &pinnedIDs)
        PinnedThemes.save(pinnedIDs)
    }
}
