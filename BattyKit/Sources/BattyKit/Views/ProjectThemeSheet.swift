// ProjectThemeSheet.swift

import AppKit
import SwiftUI

/// Edits a Project's Dark and Light Theme. Works on a local pair; Done hands
/// it to the model and Cancel writes nothing. No live preview: the editor
/// isn't bound to a Session.
struct ProjectThemeSheet: View {
    @Binding var isPresented: Bool
    let model: ProjectEditorViewModel

    @State private var pair: ThemePair
    @State private var isDarkSlot: Bool
    @State private var query = ""
    @State private var pinnedIDs: [String]

    init(isPresented: Binding<Bool>, model: ProjectEditorViewModel) {
        self._isPresented = isPresented
        self.model = model
        self._pair = State(initialValue: model.draft?.theme ?? ThemePair(dark: nil, light: nil))
        self._isDarkSlot = State(initialValue: NSApp?.effectiveAppearance.isDark ?? true)
        self._pinnedIDs = State(initialValue: PinnedThemes.load())
    }

    private var slotName: String? { pair.name(isDark: isDarkSlot) }

    private var slotIsUnavailable: Bool {
        guard let slotName else { return false }
        return BattyThemeCatalog.theme(named: slotName) == nil
    }

    private func filtered(pinned: Bool) -> [GhosttyThemeDefinition] {
        let themes = BattyThemeCatalog.allThemes.filter { PinnedThemes.contains($0.name, in: pinnedIDs) == pinned }
        guard !query.isEmpty else { return themes }
        return themes
            .filter { FuzzyMatcher.score(query, in: $0.name) > 0 }
            .sorted { FuzzyMatcher.score(query, in: $0.name) > FuzzyMatcher.score(query, in: $1.name) }
    }

    var body: some View {
        let pinned = filtered(pinned: true)
        let others = filtered(pinned: false)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Appearance", selection: $isDarkSlot) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("project-theme-sheet.slot")
                HStack(spacing: 8) {
                    Button {
                        pair = pair.with(nil, isDark: isDarkSlot)
                    } label: {
                        Label("Follow Settings", systemImage: slotName == nil ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityIdentifier("project-theme-sheet.follow")
                    .accessibilityValue(slotName == nil ? "selected" : "")
                    Spacer()
                }
                if slotIsUnavailable, let slotName {
                    Text("“\(slotName)” isn't available in this version of Batty, so the Settings Theme is used. Choose a Theme or Follow Settings to replace it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("project-theme-sheet.unavailable")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter themes\u{2026}", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("project-theme-sheet.filter")
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            sectionHeader("Pinned")
                            grid(pinned)
                        }
                        if !others.isEmpty {
                            sectionHeader(pinned.isEmpty ? "Themes" : "All Themes")
                            grid(others)
                        }
                    }
                    .padding(12)
                    .onAppear {
                        if let slotName { proxy.scrollTo(slotName, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project-theme-sheet.cancel")
                Button("Done") {
                    model.setTheme(pair)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("project-theme-sheet.done")
            }
            .padding(12)
        }
        .frame(width: 620, height: 540)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-theme-sheet.root")
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }

    private func grid(_ themes: [GhosttyThemeDefinition]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 160))], spacing: 12) {
            ForEach(themes, id: \.name) { theme in
                ThemeCard(
                    theme: theme,
                    isActive: theme.name == slotName,
                    isCursor: false,
                    isPinned: PinnedThemes.contains(theme.name, in: pinnedIDs),
                    onTogglePin: {
                        PinnedThemes.toggle(theme.name, in: &pinnedIDs)
                        PinnedThemes.save(pinnedIDs)
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture { pair = pair.with(theme.name, isDark: isDarkSlot) }
                .accessibilityIdentifier("project-theme-sheet.card.\(theme.name)")
                .id(theme.name)
            }
        }
    }
}
