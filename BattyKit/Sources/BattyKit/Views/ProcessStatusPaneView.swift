// ProcessStatusPaneView.swift

import SwiftUI

/// The `.processStatus` Pane kind's real content (`#0305`), replacing the
/// provisional placeholder `#0315` shipped. Renders exactly what
/// `docs/design/process-status-view.md`'s feasibility spike proved
/// obtainable via libproc for a same-uid target — nothing more. Every
/// state (`.running`, `.exited`, `.permissionDenied`, "no selection") is a
/// first-class banner keyed off a real kernel signal
/// (`ProcessStatusPaneContent.RunState`/`hasNoSelection`), never an
/// inferred guess — the phase-1 review's own defect (a mockup showing
/// argv data the spike had proved unobtainable behind `EPERM`) is the
/// class of bug this view must not reintroduce.
///
/// Pane-level chrome (the drag handle, the eye/hide button, click-to-
/// focus) lives one level up, in `PaneView.nonTerminalShell` — this view
/// is only the content region.
struct ProcessStatusPaneView: View {
    @Bindable var content: ProcessStatusPaneContent
    @Bindable var tree: SplitTree

    @State private var isOpenFilesExpanded = false
    @State private var isChildrenExpanded = false
    @State private var openFiles: [ProcessInspector.OpenFileDescriptor] = []
    @State private var childProcesses: [ProcessInspector.ChildProcess] = []
    /// Populated only inside `pickRunningProcess()`'s `Button` action
    /// (review round 1, S4) — never computed inline inside a `Menu`'s
    /// content closure. `chooseProcessMenu` is a plain computed property
    /// evaluated as part of `body`, and `body` re-evaluates once a second
    /// because it observes `content.snapshot`; a `Menu`'s `@ViewBuilder`
    /// content is ordinary Swift code executed at that same moment (this
    /// is not a question of AppKit's own NSMenu-population laziness — the
    /// `ProcessInspector.allSameUserProcesses()` call was a plain
    /// statement inside the property getter, unconditionally run every
    /// time the getter ran). Measured: 2.6-3.6 ms for ~470 processes plus
    /// ~470 constructed `Button` views, once a second, against the
    /// design's ~0.03 ms/tick budget (§4). A `Button` action closure, by
    /// contrast, is unambiguously invoked only on an actual click.
    @State private var runningProcessesCache: [ProcessInspector.RunningProcess] = []
    @State private var isPickingProcess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if content.hasNoSelection {
                    noSelectionState
                } else {
                    switch content.runState {
                    case .running:
                        metricsRow
                        commandLineRow
                        disclosures
                    case .exited:
                        exitedBanner
                        lastKnownMetricsRow
                        disclosures
                    case .permissionDenied:
                        permissionDeniedBanner
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("process-status-view")
    }

    // MARK: - Header (§3.1)

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(content.snapshot?.name ?? "No process selected")
                        .font(.headline)
                        .lineLimit(1)
                    if let pid = content.snapshot?.pid {
                        Text("pid \(pid)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu { headerContextMenu }
                HStack(spacing: 8) {
                    modeIndicator
                    stateChip
                }
            }
            Spacer(minLength: 12)
            chooseProcessMenu
        }
    }

    @ViewBuilder
    private var headerContextMenu: some View {
        if let snapshot = content.snapshot {
            Button("Copy PID") {
                copyToPasteboard("\(snapshot.pid)")
            }
            if let commandLine = snapshot.commandLine {
                Button("Copy Command Line") {
                    copyToPasteboard(commandLine)
                }
            }
            if let path = snapshot.executablePath {
                Button("Reveal Executable in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @ViewBuilder
    private var modeIndicator: some View {
        switch content.target {
        case .pinned:
            Label("Pinned", systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .followingTab(let tabID):
            Label("Following \(followedTabTitle(tabID))", systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func followedTabTitle(_ tabID: UUID) -> String {
        guard let tab = tree.allPanes.flatMap(\.tabs).first(where: { $0.id == tabID }) else {
            return "a closed Tab"
        }
        return TabTitleFormatter.chipTitle(for: tab)
    }

    @ViewBuilder
    private var stateChip: some View {
        if !content.hasNoSelection {
            switch content.runState {
            case .running:
                chip("Running", color: .green)
            case .exited:
                chip("Exited", color: .secondary)
            case .permissionDenied:
                chip("Permission Unavailable", color: .orange)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - "Choose Process…" (§2's retarget action)

    private var chooseProcessMenu: some View {
        Menu("Choose Process…") {
            Menu("Follow a Terminal Pane…") {
                let terminalPanes = tree.allPanes.filter { $0.kind == .terminal }
                if terminalPanes.isEmpty {
                    Text("No terminal panes in this session")
                } else {
                    ForEach(terminalPanes) { pane in
                        Button(terminalPaneLabel(pane)) {
                            content.retarget(to: .followingTab(pane.activeTabID))
                        }
                    }
                }
            }
            Button("Pick a Running Process…") {
                runningProcessesCache = ProcessInspector.allSameUserProcesses()
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                isPickingProcess = true
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityIdentifier("process-status.choose-process")
        .popover(isPresented: $isPickingProcess) {
            runningProcessPicker
        }
    }

    /// The list `pickRunningProcess`'s `Button` action populates
    /// `runningProcessesCache` for — a `.popover`, not a nested `Menu`, so
    /// the (already-fetched, already-cheap-to-render-from-`@State`) list
    /// is unambiguously built once per open rather than re-built on every
    /// `body` re-evaluation.
    private var runningProcessPicker: some View {
        List(runningProcessesCache) { process in
            Button {
                content.retarget(to: .pinned(process.id))
                isPickingProcess = false
            } label: {
                HStack {
                    Text(process.name)
                    Spacer()
                    Text("\(process.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 260, minHeight: 320)
        .accessibilityIdentifier("process-status.running-process-picker")
    }

    private func terminalPaneLabel(_ pane: PaneRuntime) -> String {
        guard let tab = pane.tabs.first(where: { $0.id == pane.activeTabID }) else {
            return "Terminal"
        }
        return TabTitleFormatter.chipTitle(for: tab)
    }

    // MARK: - Metrics (§3.2)

    private var metricsRow: some View {
        HStack(spacing: 20) {
            metricTile("CPU", value: content.snapshot?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
            metricTile("Memory", value: content.snapshot?.physFootprintBytes.map(formattedBytes) ?? "—", detail: content.snapshot?.residentBytes.map { "Resident: \(formattedBytes($0))" })
            metricTile("Threads", value: content.snapshot?.threadCount.map(String.init) ?? "—")
            metricTile("Open Files", value: content.snapshot?.openFileCount.map(String.init) ?? "—")
        }
    }

    private var lastKnownMetricsRow: some View {
        metricsRow
            .opacity(0.55)
    }

    private func metricTile(_ label: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .help(detail ?? "")
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - Command line (§3.3)

    @ViewBuilder
    private var commandLineRow: some View {
        if let commandLine = content.snapshot?.commandLine, !commandLine.isEmpty {
            Text(commandLine)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy Command Line") { copyToPasteboard(commandLine) }
                }
        }
    }

    // MARK: - Banners (§3.5/§3.6)

    /// Review round 1, B5: this must not assert a fact this type never
    /// observed. The design specifies "the timestamp of the last
    /// successful sample" — `content.snapshot?.capturedAt` — not the
    /// instant the exit was *detected*, which can be up to a full refresh
    /// interval later, and is nonexistent for a pid that was already dead
    /// the very first time it was sampled (in which case there is no
    /// "last seen" to show at all).
    private var exitedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
            if let capturedAt = content.snapshot?.capturedAt {
                Text("Process exited — last seen \(capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.callout)
            } else {
                Text("Process exited")
                    .font(.callout)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var permissionDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text("Permission unavailable — not owned by you")
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var noSelectionState: some View {
        VStack(spacing: 8) {
            Text("No process selected")
                .font(.title3.weight(.semibold))
            Text("Use “Choose Process…” to follow a terminal pane or pick a running process.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Disclosures (§3.4 — on-demand, never per-tick)

    @ViewBuilder
    private var disclosures: some View {
        DisclosureGroup("Open Files (\(openFiles.count))", isExpanded: $isOpenFilesExpanded) {
            ForEach(openFiles) { fd in
                HStack {
                    Text("fd \(fd.id)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(fd.path ?? (fd.isVnode ? "(unresolved)" : "(non-file descriptor)"))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .onChange(of: isOpenFilesExpanded) { _, expanded in
            guard expanded else { return }
            openFiles = content.openFiles()
        }

        DisclosureGroup("Child Processes (\(childProcesses.count))", isExpanded: $isChildrenExpanded) {
            ForEach(childProcesses) { child in
                HStack {
                    Text(child.name)
                        .font(.caption.monospaced())
                    Text("pid \(child.id)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Watch this instead") {
                        content.watchInstead(pid: child.id)
                    }
                    .font(.caption)
                }
            }
        }
        .onChange(of: isChildrenExpanded) { _, expanded in
            guard expanded else { return }
            childProcesses = content.childProcesses()
        }
    }
}
