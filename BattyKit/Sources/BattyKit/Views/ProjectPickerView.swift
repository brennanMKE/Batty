// ProjectPickerView.swift

import AppKit
import BattyXPCCore
import SwiftUI

extension Notification.Name {
    public static let battyToggleProjectPicker = Notification.Name("co.sstools.Batty.toggleProjectPicker")
}

enum ProjectPickerToggle {
    static let windowIDKey = "windowID"

    /// A toggle that names a window is handled by that window alone, key or
    /// not; one that names none is handled by the key window.
    static func shouldHandle(userInfo: [AnyHashable: Any]?, windowID: WindowID, isKeyWindow: Bool) -> Bool {
        guard let target = userInfo?[windowIDKey] as? WindowID else { return isKeyWindow }
        return target == windowID
    }
}

/// The Open Project sheet. It only reports what the person chose; the host
/// dismisses the sheet first and then acts, so the startup-command trust
/// sheet can present from the same view.
struct ProjectPickerView: View {
    static let windowIdentifier = "project-picker"

    let projects: () -> [Project]
    let openProjectIDs: () -> Set<UUID>
    let onAction: (ProjectPickerAction) -> Void
    let onCancel: () -> Void

    @State private var base: ProjectPickerModel
    @FocusState private var filterFocused: Bool

    /// `projects` and `openProjectIDs` are read on every render, so the cards
    /// and OPEN badges follow edits made elsewhere while the sheet is up.
    init(
        projects: @escaping () -> [Project],
        openProjectIDs: @escaping () -> Set<UUID>,
        homeDirectory: String = NSHomeDirectory(),
        onAction: @escaping (ProjectPickerAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _base = State(initialValue: ProjectPickerModel(
            projects: projects(), openProjectIDs: openProjectIDs(), homeDirectory: homeDirectory))
        self.projects = projects
        self.openProjectIDs = openProjectIDs
        self.onAction = onAction
        self.onCancel = onCancel
    }

    private var model: ProjectPickerModel {
        get { base.refreshed(projects: projects(), openProjectIDs: openProjectIDs()) }
        nonmutating set { base = newValue }
    }

    var body: some View {
        let current = model
        VStack(spacing: 0) {
            HStack {
                Text("Open a Project").font(.headline)
                Spacer()
                Text(current.isFiltering ? LocalizedStringKey("Esc to clear") : LocalizedStringKey("Esc to dismiss")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            filterField

            Divider()

            if let empty = current.emptyState {
                emptyState(empty)
            } else {
                tiers(current)
            }

            footer
        }
        .frame(width: 860, height: 600)
        .background(.regularMaterial)
        .background(ProjectPickerWindowTag())
        .background(shortcutButtons)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-picker.root")
        .onAppear { filterFocused = true }
    }

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                "Filter Projects",
                text: Binding(get: { model.query }, set: { model.setQuery($0) })
            )
            .textFieldStyle(.plain)
            .focused($filterFocused)
            .onKeyPress(.leftArrow) { model.move(.left); return .handled }
            .onKeyPress(.rightArrow) { model.move(.right); return .handled }
            .onKeyPress(.upArrow) { model.move(.up); return .handled }
            .onKeyPress(.downArrow) { model.move(.down); return .handled }
            .onKeyPress(keys: [.return], phases: .down) { press in
                if let action = model.openAction(optionHeld: press.modifiers.contains(.option)) {
                    onAction(action)
                }
                return .handled
            }
            .onKeyPress(.home) { model.move(.home); return .handled }
            .onKeyPress(.end) { model.move(.end); return .handled }
            .onKeyPress(.escape) {
                if model.escape() == .dismiss { onCancel() }
                return .handled
            }
            .accessibilityIdentifier("project-picker.filter")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func tiers(_ current: ProjectPickerModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if current.isFiltering {
                        tier(
                            heading: current.matchCountText,
                            cards: current.rest, style: .compact, columns: ProjectPickerModel.restColumns, spacing: 10,
                            selectedID: current.selectedID, identifier: "project-picker.rest")
                    } else {
                        tier(
                            heading: current.showsTierHeadings ? String(localized: "Recent", comment: "Open Project picker: heading above the most recently opened Projects") : nil,
                            cards: current.featured, style: .large, columns: ProjectPickerModel.featuredColumns, spacing: 12,
                            selectedID: current.selectedID, identifier: "project-picker.featured",
                            showsNewProjectCard: current.showsNewProjectCard)
                        if !current.rest.isEmpty {
                            tier(
                                heading: String(localized: "All Projects", comment: "Open Project picker: heading above the remaining Projects"),
                                cards: current.rest, style: .compact, columns: ProjectPickerModel.restColumns, spacing: 10,
                                selectedID: current.selectedID, identifier: "project-picker.rest")
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: current.selectedPosition) { _, position in
                if let id = position?.id { proxy.scrollTo(id) }
            }
        }
    }

    private func tier(
        heading: String?,
        cards: [ProjectPickerCard],
        style: ProjectPickerCardView.Style,
        columns: Int,
        spacing: CGFloat,
        selectedID: UUID?,
        identifier: String,
        showsNewProjectCard: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading {
                Text(heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
                ForEach(cards) { card in
                    ProjectPickerCardView(card: card, style: style, isSelected: card.id == selectedID, now: Date())
                        .id(card.id)
                        .onTapGesture(count: 2) {
                            model.select(card.id)
                            if let action = model.openAction(optionHeld: false) { onAction(action) }
                        }
                        .onTapGesture { model.select(card.id) }
                }
                if showsNewProjectCard {
                    newProjectCard
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var newProjectCard: some View {
        Button { onAction(.newProject) } label: {
            ProjectPickerCardView.largeSizingStack
                .hidden()
                .padding(10)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 28))
                        Text("New Project\u{2026}").fontWeight(.semibold)
                    }
                    .foregroundStyle(.secondary)
                }
                .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("project-picker.new-project-card")
    }

    @ViewBuilder
    private func emptyState(_ state: ProjectPickerEmptyState) -> some View {
        VStack(spacing: 10) {
            switch state {
            case .noProjects:
                Image(systemName: "folder.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("No Projects yet").font(.title3.weight(.semibold))
                Text("A Project opens a Session with its folder, color, layout and startup commands already set up.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("New Project\u{2026}") { onAction(.newProject) }
                    .controlSize(.large)
                    .accessibilityIdentifier("project-picker.new-project")
            case .noMatches:
                Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("No Projects Found").font(.title3.weight(.semibold))
                Text("Try a different search term.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-picker.empty")
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Text(model.hint)
                .fontWeight(.semibold)
                .accessibilityLabel(Text(model.hint))
                .accessibilityIdentifier("project-picker.hint")
            Spacer()
            if model.selectedID != nil {
                Text("\u{2325}\u{21A9} Open another copy")
                Text("\u{2318}E Edit")
            }
            Text("\u{2318}N New Project\u{2026}")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    /// Command-N is File > New Session and Command-E is the default for
    /// Pane > Open View > System Metrics
    /// (`ShortcutAction.splitHorizontalSystemMetrics`).
    /// `BattyShortcuts` acts only when a registered content window is key,
    /// which a sheet is not, so it leaves both chords alone. These buttons register the chords as key
    /// equivalents of this sheet so they are meant to be offered here before
    /// the main menu sees them; `onKeyPress` would be too late for a Command
    /// chord. The check that Command-N creates no Session and Command-E adds
    /// no Pane is manual
    /// (`docs/ui-features.md`, Open Project picker).
    private var shortcutButtons: some View {
        HStack {
            Button("Edit Project") {
                if let action = model.editAction() { onAction(action) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.selectedID == nil)
            Button("New Project") { onAction(.newProject) }
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct ProjectPickerCardView: View {
    enum Style {
        case large, compact

        var thumbnailHeight: CGFloat { self == .large ? 132 : 58 }
    }

    let card: ProjectPickerCard
    let style: Style
    let isSelected: Bool
    let now: Date

    /// Invisible stand-in with a large card's vertical structure, so the New
    /// Project card is exactly as tall as the cards beside it.
    static var largeSizingStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Style.large.thumbnailHeight)
            Text(" ").font(.system(size: 14, weight: .semibold)).padding(.top, 10)
            Text(" ").font(.caption).padding(.top, 2)
            Text(" ").font(.caption).padding(.top, 2)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            HStack(spacing: 8) {
                Image(systemName: card.symbol.resolvedSystemName)
                    .foregroundStyle(card.color.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(card.name)
                    .font(style == .large ? .system(size: 14, weight: .semibold) : .body.weight(.semibold))
                    .lineLimit(1)
                let opened = style == .large ? ProjectRecency.relativeOpenedText(card.lastOpenedAt, now: now) : nil
                if opened != nil || card.isOpen {
                    Spacer(minLength: 4)
                }
                if let opened {
                    Text(opened).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if card.isOpen {
                    Text("OPEN")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                        .accessibilityIdentifier("project-picker.open-badge.\(card.name)")
                }
            }
            .padding(.top, 10)
            Text(card.displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 2)
            if style == .large {
                Text(card.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: isSelected ? .controlBackgroundColor : .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("project-picker.card.\(card.name)")
    }

    private var thumbnail: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(card.slots.enumerated()), id: \.offset) { _, slot in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(slot.kind.projectEditorColor.opacity(0.4)))
                        .overlay {
                            if style == .large {
                                Text(slot.kind.projectEditorGlyph)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.85))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(slot.kind.projectEditorColor))
                            }
                        }
                        .padding(3)
                        .frame(width: slot.frame.width * geometry.size.width, height: slot.frame.height * geometry.size.height)
                        .offset(x: slot.frame.minX * geometry.size.width, y: slot.frame.minY * geometry.size.height)
                }
            }
        }
        .frame(height: style.thumbnailHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

/// Names the sheet's own `NSWindow` while the picker is in it, and clears the
/// name when the picker leaves, so `AppStateStore.projectPickerIsKey` can recognize it.
private struct ProjectPickerWindowTag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TagView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TagView: NSView {
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window?.identifier?.rawValue == ProjectPickerView.windowIdentifier {
                window?.identifier = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier(ProjectPickerView.windowIdentifier)
        }
    }
}
