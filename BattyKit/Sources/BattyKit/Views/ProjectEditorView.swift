// ProjectEditorView.swift

import AppKit
import BattyXPCCore
import SwiftUI

extension PaneContentKind {
    var projectEditorGlyph: String {
        switch self {
        case .terminal: ">_"
        case .gitStatus: "\u{2387}"
        case .processStatus: "\u{2261}"
        case .systemMetrics: "\u{25A5}"
        case .lmStudioDashboard: "LM"
        }
    }

    var projectEditorColor: Color {
        let hex: String = switch self {
        case .terminal: "#7AA2F7"
        case .gitStatus: "#F2A65A"
        case .processStatus: "#5CC8B0"
        case .systemMetrics: "#B48EF0"
        case .lmStudioDashboard: "#F07FA8"
        }
        return RGBColor(hex: hex)?.swiftUIColor ?? .gray
    }

    var projectEditorBlurb: String {
        switch self {
        case .terminal: ""
        case .gitStatus: String(localized: "Branch, changes and recent commits for a repository.", comment: "Project Editor: Git Status view blurb")
        case .processStatus: String(localized: "Live process list.", comment: "Project Editor: Process Status view blurb")
        case .systemMetrics: String(localized: "CPU, memory and GPU load for this Mac.", comment: "Project Editor: System Metrics view blurb")
        case .lmStudioDashboard: String(localized: "Loaded models and server status from LM Studio.", comment: "Project Editor: LM Studio view blurb")
        }
    }

    var projectEditorIdentifier: String { rawValue }
}

enum ProjectEditorPanels {
    /// Presented from a button action only, never from a view update.
    static func chooseDirectory(startingAt url: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = url
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct PendingPresetChange: Identifiable {
    let id = UUID()
    let preset: PaneLayout
    let droppedSlots: [Int]
}

struct ProjectEditorView: View {
    let model: ProjectEditorViewModel

    @State private var pendingPreset: PendingPresetChange?
    @State private var pendingCopy = false

    var body: some View {
        HStack(spacing: 0) {
            ProjectListColumn(model: model)
                .frame(width: 220)
            Divider()
            if model.draft != nil {
                ProjectEditorMain(model: model, pendingPreset: $pendingPreset, pendingCopy: $pendingCopy)
            } else {
                ProjectEditorEmptyState(model: model)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .confirmationDialog(
            String(localized: "Save changes to this Project?", comment: "Project Editor unsaved-changes question"),
            isPresented: Binding(
                get: { model.pendingNavigation != nil },
                set: { if !$0 { model.resolveUnsaved(.cancel) } }
            )
        ) {
            Button("Save") { model.resolveUnsaved(.save) }
            Button("Discard Changes", role: .destructive) { model.resolveUnsaved(.discard) }
            Button("Cancel", role: .cancel) { model.resolveUnsaved(.cancel) }
        } message: {
            Text("Your changes will be lost if you discard them.")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            )
        ) {
            Button("Delete", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("This removes the Project definition. Sessions already open from it stay open.")
        }
        .confirmationDialog(
            String(localized: "Remove panes?", comment: "Project Editor: changing the layout drops configured Panes"),
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } }
            ),
            presenting: pendingPreset
        ) { change in
            Button("Remove Panes", role: .destructive) {
                model.changePreset(to: change.preset, confirmDrop: true)
                pendingPreset = nil
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: { change in
            Text(droppedMessage(change.droppedSlots))
        }
        .confirmationDialog(
            String(localized: "Replace this layout?", comment: "Project Editor: Copy from current Session would discard configured Panes"),
            isPresented: $pendingCopy
        ) {
            Button("Replace", role: .destructive) {
                model.copyFromCurrentSession(confirmDiscard: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Tabs, commands and views set up in this Project's Panes will be replaced by those of the current Session.")
        }
    }

    private var deletionTitle: String {
        let name = model.pendingDeletion.flatMap { model.store.project(id: $0)?.name } ?? ""
        return String(localized: "Delete \u{201C}\(name)\u{201D}?", comment: "Project Editor: delete confirmation title")
    }

    private func droppedMessage(_ slots: [Int]) -> String {
        let numbers = slots.map { String($0 + 1) }.formatted(.list(type: .and))
        return String(localized: "The layout has fewer panes. The Tabs, commands and views set up in Pane \(numbers) will be removed.", comment: "Project Editor: panes dropped by a layout change")
    }
}

private struct ProjectEditorEmptyState: View {
    let model: ProjectEditorViewModel

    var body: some View {
        VStack(spacing: 12) {
            Text("No Projects yet")
                .font(.headline)
            Text("A Project opens a Session with its folder, color, layout and startup commands already set up.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Project\u{2026}") { model.requestNewProject() }
                .accessibilityIdentifier("project-editor.empty.new-project")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Projects list

private struct ProjectListColumn: View {
    let model: ProjectEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PROJECTS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
            List(
                selection: Binding<UUID?>(
                    get: { model.selectedID },
                    set: { if let id = $0 { model.requestSelect(id) } }
                )
            ) {
                ForEach(model.listEntries) { entry in
                    ProjectListRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Move Up") { model.moveProject(entry.id, by: -1) }
                                .disabled(!model.canMoveProject(entry.id, by: -1))
                            Button("Move Down") { model.moveProject(entry.id, by: 1) }
                                .disabled(!model.canMoveProject(entry.id, by: 1))
                            Divider()
                            Button("Delete\u{2026}", role: .destructive) { model.requestDelete(entry.id) }
                        }
                }
                .onMove { model.moveProjects(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let id = model.selectedID { model.requestDelete(id) }
            }
            .accessibilityIdentifier("project-editor.list")

            Button {
                model.requestNewProject()
            } label: {
                Label("New Project\u{2026}", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .padding(10)
            .accessibilityIdentifier("project-editor.new-project")
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ProjectListRow: View {
    let entry: ProjectEditorListEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol.resolvedSystemName)
                .foregroundStyle(entry.color.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(entry.isUnsavedNew ? "project-editor.list.row.new" : "project-editor.list.row.\(entry.name)")
    }
}

// MARK: - Main column

private struct ProjectEditorMain: View {
    let model: ProjectEditorViewModel
    @Binding var pendingPreset: PendingPresetChange?
    @Binding var pendingCopy: Bool

    var body: some View {
        let validation = model.validate()
        VStack(spacing: 0) {
            ProjectHeaderFields(model: model, validation: validation)
            Divider()
            HStack(spacing: 0) {
                ProjectLayoutSection(model: model, pendingPreset: $pendingPreset, pendingCopy: $pendingCopy)
                Divider()
                PaneInspector(model: model, validation: validation)
                    .frame(width: 340)
            }
            Divider()
            ProjectEditorFooter(model: model, validation: validation)
        }
    }
}

private struct FieldMessages: View {
    let error: String?
    let warning: String?
    let identifier: String

    var body: some View {
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).error")
        } else if let warning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).warning")
        }
    }
}

private struct ProjectHeaderFields: View {
    let model: ProjectEditorViewModel
    let validation: ProjectEditorValidation

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.setName($0) }), prompt: Text("Project name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("project-editor.name")
                FieldMessages(error: validation.errors[.name], warning: nil, identifier: "project-editor.name")
            }
            .frame(width: 200)

            VStack(alignment: .leading, spacing: 6) {
                Text("Root folder").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Root folder", text: Binding(get: { model.draft?.rootPath ?? "" }, set: { model.setRootPath($0) }), prompt: Text("/path/to/folder"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("project-editor.root")
                    Button("Choose\u{2026}") { chooseRoot() }
                        .accessibilityIdentifier("project-editor.root.choose")
                }
                FieldMessages(error: validation.errors[.root], warning: nil, identifier: "project-editor.root")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Session color").font(.caption).foregroundStyle(.secondary)
                ProjectColorSwatches(model: model)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Symbol").font(.caption).foregroundStyle(.secondary)
                ProjectSymbolPicker(model: model)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func chooseRoot() {
        let current = model.draft.map { URL(fileURLWithPath: ProjectDraft.normalizedRoot($0.rootPath)) }
        if let url = ProjectEditorPanels.chooseDirectory(
            startingAt: current,
            message: String(localized: "Choose the Project's root folder", comment: "Project Editor: open panel message")
        ) {
            model.applyChosenRoot(url)
        }
    }
}

private struct ProjectColorSwatches: View {
    let model: ProjectEditorViewModel
    @FocusState private var isFocused: Bool

    private var selected: SessionColor { model.draft?.color ?? .blue }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SessionColor.allCases, id: \.rawValue) { color in
                Button {
                    model.setColor(color)
                    isFocused = true
                } label: {
                    ZStack {
                        Circle().fill(color.color).frame(width: 18, height: 18)
                        if color == selected {
                            Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: 24, height: 24)
                        }
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color.displayName))
                .accessibilityAddTraits(color == selected ? .isSelected : [])
                .accessibilityIdentifier("project-editor.color.\(String(describing: color))")
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    private func step(_ delta: Int) {
        let all = SessionColor.allCases
        guard let index = all.firstIndex(of: selected) else { return }
        let next = index + delta
        if all.indices.contains(next) { model.setColor(all[next]) }
    }
}

// MARK: - Layout strip and pane preview

private struct ProjectLayoutSection: View {
    let model: ProjectEditorViewModel
    @Binding var pendingPreset: PendingPresetChange?
    @Binding var pendingCopy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Layout").fontWeight(.semibold)
                Spacer()
                Button("Copy from current Session") {
                    if model.copyFromCurrentSession() == .needsConfirmation { pendingCopy = true }
                }
                .help(String(localized: "Replace the layout, Pane kinds and Tabs with those of the selected Session. Pane sizes are not copied.", comment: "Project Editor: Copy from current Session help"))
                .accessibilityIdentifier("project-editor.copy-from-session")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(PaneLayout.allCases) { layout in
                    Button {
                        if case .needsConfirmation(let slots) = model.changePreset(to: layout) {
                            pendingPreset = PendingPresetChange(preset: layout, droppedSlots: slots)
                        }
                    } label: {
                        LayoutThumbnailView(
                            layout: layout,
                            isSelected: model.draft?.layout.preset == layout,
                            themeChrome: nil,
                            size: CGSize(width: 64, height: 44)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(layout.name)
                    .accessibilityLabel(Text(layout.name))
                    .accessibilityAddTraits(model.draft?.layout.preset == layout ? .isSelected : [])
                    .accessibilityIdentifier("project-editor.layout.\(layout.rawValue)")
                }
                if let draft = model.draft, draft.layout.preset == nil {
                    LayoutThumbnailView(
                        panes: draft.layout.thumbnailPanes,
                        isSelected: true,
                        themeChrome: nil,
                        size: CGSize(width: 64, height: 44)
                    )
                    .help(String(localized: "Custom", comment: "Project Editor: a layout that is not one of the presets"))
                    .accessibilityLabel(Text("Custom"))
                    .accessibilityAddTraits(.isSelected)
                    .accessibilityIdentifier("project-editor.layout.custom")
                }
            }

            PanePreview(model: model)

            Text("Click a pane to set it up. Panes open at equal sizes; resize them freely afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PanePreview: View {
    let model: ProjectEditorViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let frames = model.slotFrames
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.panes.enumerated()), id: \.offset) { slot, pane in
                    if frames.indices.contains(slot) {
                        let frame = frames[slot]
                        PaneCard(
                            slot: slot,
                            pane: pane,
                            tabs: model.tabSummaries(slot: slot),
                            isSelected: slot == model.selectedSlot
                        ) {
                            model.selectSlot(slot)
                            isFocused = true
                        }
                        .frame(
                            width: max(frame.width * geometry.size.width - 8, 0),
                            height: max(frame.height * geometry.size.height - 8, 0)
                        )
                        .offset(x: frame.minX * geometry.size.width + 4, y: frame.minY * geometry.size.height + 4)
                    }
                }
            }
        }
        .padding(6)
        .frame(minHeight: 220, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { model.moveSelection(.left); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(.right); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(.up); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(.down); return .handled }
        .accessibilityIdentifier("project-editor.preview")
    }
}

private struct KindBadge: View {
    let kind: PaneContentKind
    var compact = false

    var body: some View {
        Text(kind.projectEditorGlyph)
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 4)
            .frame(minWidth: compact ? 22 : 24, minHeight: compact ? 18 : 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(kind.projectEditorColor))
            .accessibilityHidden(true)
    }
}

private struct PaneCard: View {
    let slot: Int
    let pane: ProjectPane
    let tabs: [ProjectEditorTabSummary]
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    KindBadge(kind: pane.kind)
                    Text(pane.kind.displayName).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Pane \(slot + 1)").font(.caption).foregroundStyle(.secondary)
                }
                switch pane.kind {
                case .terminal:
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                            Text(tab.title)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(index == 0 ? Color.primary.opacity(0.12) : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(index == 0 ? Color.clear : Color(nsColor: .separatorColor)))
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                            (Text(tab.title).foregroundStyle(.secondary) + Text(" ") + Text(tab.line))
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                case .gitStatus:
                    let relative = pane.repositoryPath.map { $0 == "." ? "" : $0 } ?? ""
                    Text(String(localized: "Repository: root/\(relative)", comment: "Project Editor: Git Status Pane card; the argument is the relative folder"))
                        .foregroundStyle(.secondary)
                case .processStatus, .systemMetrics, .lmStudioDashboard:
                    Text(pane.kind.projectEditorBlurb).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: isSelected ? .controlBackgroundColor : .windowBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Pane \(slot + 1): \(pane.kind.displayName)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("project-editor.pane.\(slot + 1)")
    }
}

// MARK: - Inspector

private struct PaneInspector: View {
    let model: ProjectEditorViewModel
    let validation: ProjectEditorValidation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pane \(model.selectedSlot + 1)").fontWeight(.semibold)
                    Spacer()
                    Text(model.selectedPosition).font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shows").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(PaneContentKind.allCases, id: \.self) { kind in
                            KindButton(kind: kind, isSelected: model.selectedPane?.kind == kind) {
                                model.setKind(kind)
                            }
                        }
                    }
                }

                if let pane = model.selectedPane {
                    switch pane.kind {
                    case .terminal:
                        TabsEditor(model: model, validation: validation, pane: pane)
                    case .gitStatus:
                        RelativeFolderField(
                            title: String(localized: "Repository folder", comment: "Project Editor: Git Status Pane setting"),
                            placeholder: ".",
                            text: Binding(get: { model.selectedPane?.repositoryPath ?? "" }, set: { model.setRepositoryPath($0) }),
                            error: validation.errors[.repository(slot: model.selectedSlot)],
                            warning: validation.warnings[.repository(slot: model.selectedSlot)],
                            identifier: "project-editor.repository",
                            choose: { chooseFolder(tab: nil) }
                        )
                    case .processStatus, .systemMetrics, .lmStudioDashboard:
                        Text("\(pane.kind.projectEditorBlurb) Nothing to set up for this view.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("project-editor.inspector")
    }

    private func chooseFolder(tab: Int?) {
        guard let draft = model.draft else { return }
        let root = URL(fileURLWithPath: ProjectDraft.normalizedRoot(draft.rootPath), isDirectory: true)
        if let url = ProjectEditorPanels.chooseDirectory(
            startingAt: root,
            message: String(localized: "Choose a folder inside the Project's root folder", comment: "Project Editor: open panel message")
        ) {
            model.applyChosenDirectory(url, tab: tab)
        }
    }
}

private struct KindButton: View {
    let kind: PaneContentKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                KindBadge(kind: kind, compact: true)
                Text(kind.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: isSelected ? .selectedControlColor : .windowBackgroundColor).opacity(isSelected ? 0.25 : 1)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("project-editor.kind.\(kind.projectEditorIdentifier)")
    }
}

private struct RelativeFolderField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let error: String?
    let warning: String?
    let identifier: String
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text("root/")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                    TextField(title, text: $text, prompt: Text(placeholder))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier(identifier)
                }
                .frame(minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(error == nil ? Color(nsColor: .separatorColor) : Color.red))
                Button(action: choose) {
                    Image(systemName: "folder")
                }
                .help(String(localized: "Choose a folder inside the root", comment: "Project Editor: folder chooser tooltip"))
                .accessibilityLabel(Text("Choose folder"))
                .accessibilityIdentifier("\(identifier).choose")
            }
            FieldMessages(error: error, warning: warning, identifier: identifier)
        }
    }
}

private struct TabsEditor: View {
    let model: ProjectEditorViewModel
    let validation: ProjectEditorValidation
    let pane: ProjectPane

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tabs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("+ Add Tab") { model.addTab() }
                    .controlSize(.small)
                    .accessibilityIdentifier("project-editor.add-tab")
            }
            ForEach(Array(model.selectedTabIDs.enumerated()), id: \.element) { index, _ in
                TabCard(model: model, validation: validation, index: index, canRemove: pane.tabs.count > 1)
            }
            Text("Each command is typed into its Tab's shell once the shell is ready. When it exits, the Tab stays open at the prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TabCard: View {
    let model: ProjectEditorViewModel
    let validation: ProjectEditorValidation
    let index: Int
    let canRemove: Bool

    private var slot: Int { model.selectedSlot }
    private var number: Int { index + 1 }
    private var tab: ProjectTab? {
        guard let pane = model.selectedPane, pane.tabs.indices.contains(index) else { return nil }
        return pane.tabs[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                TextField("Tab title", text: Binding(get: { tab?.title ?? "" }, set: { model.setTabTitle(index, $0) }), prompt: Text("Tab title (optional)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("project-editor.tab.\(number).title")
                if canRemove {
                    Button {
                        model.removeTab(at: index)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("Remove tab"))
                    .accessibilityIdentifier("project-editor.tab.\(number).remove")
                }
            }
            RelativeFolderField(
                title: String(localized: "Working directory", comment: "Project Editor: Tab setting"),
                placeholder: ".",
                text: Binding(get: { tab?.workingDirectory ?? "" }, set: { model.setTabDirectory(index, $0) }),
                error: validation.errors[.tabDirectory(slot: slot, tab: index)],
                warning: validation.warnings[.tabDirectory(slot: slot, tab: index)],
                identifier: "project-editor.tab.\(number).directory",
                choose: { chooseFolder() }
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Startup command").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text("$")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 8)
                    TextField(
                        "Startup command",
                        text: Binding(get: { tab?.startupCommand ?? "" }, set: { model.setTabCommand(index, $0) }),
                        prompt: Text("none \u{2014} just a shell")
                    )
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("project-editor.tab.\(number).command")
                }
                .frame(minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(validation.errors[.tabCommand(slot: slot, tab: index)] == nil ? Color(nsColor: .separatorColor) : Color.red)
                )
                FieldMessages(
                    error: validation.errors[.tabCommand(slot: slot, tab: index)],
                    warning: nil,
                    identifier: "project-editor.tab.\(number).command"
                )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func chooseFolder() {
        guard let draft = model.draft else { return }
        let root = URL(fileURLWithPath: ProjectDraft.normalizedRoot(draft.rootPath), isDirectory: true)
        if let url = ProjectEditorPanels.chooseDirectory(
            startingAt: root,
            message: String(localized: "Choose a folder inside the Project's root folder", comment: "Project Editor: open panel message")
        ) {
            model.applyChosenDirectory(url, tab: index)
        }
    }
}

// MARK: - Footer

private struct ProjectEditorFooter: View {
    let model: ProjectEditorViewModel
    let validation: ProjectEditorValidation

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "Run startup commands when the Project opens",
                isOn: Binding(
                    get: { model.draft?.runStartupCommandsOnOpen ?? false },
                    set: { model.setRunStartupCommandsOnOpen($0) }
                )
            )
            .accessibilityIdentifier("project-editor.run-commands")
            Spacer()
            if let error = model.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("project-editor.save-error")
            }
            Button("Cancel") { model.cancel() }
                .accessibilityIdentifier("project-editor.cancel")
            Button("Save") { model.save() }
                .disabled(!model.canSave(validation))
                .accessibilityIdentifier("project-editor.save")
            Button("Save & Open") { model.saveAndOpen() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSaveAndOpen(validation))
                .accessibilityIdentifier("project-editor.save-open")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
