// StatusPaneLayoutConvergenceTests.swift

import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import BattyKit

private nonisolated final class TickingGitScanner: GitStatusScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0

    func scan(atPath path: String) async -> GitStatusScanResult {
        let count = lock.withLock {
            scans += 1
            return scans
        }
        var lines = [
            "# branch.head main",
            "1 .M N... 100644 100644 100644 aaaa bbbb changed.txt",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
        ]
        if count.isMultiple(of: 2) {
            lines.append("1 .M N... 100644 100644 100644 aaaa bbbb a/much/longer/path/to/another/changed-file-name.swift")
        }
        return .snapshot(GitStatusRawScan(
            statusOutput: lines.joined(separator: "\u{0}"),
            operationMarker: .none,
            submoduleParentName: nil,
            isWorktree: false,
            repositoryToplevel: "/tmp/example-repo"
        ))
    }

    func diff(atPath path: String, relativeFilePath: String, staged: Bool) async -> String? {
        (0..<30).map { "+added line \($0) for \(relativeFilePath), long enough to need sideways scrolling in a narrow Pane" }
            .joined(separator: "\n")
    }

    func terminateIfRunning() {}
    func terminateAndWaitBriefly() {}
    func waitForPendingTeardownSynchronously() {}
}

private nonisolated final class InertGitWatcher: GitStatusWatching, @unchecked Sendable {
    func start() {}
    func stop() {}
}

/// Each call returns a different snapshot: new CPU and memory values and a
/// re-sorted process list, like a real 1 s sample.
@MainActor
private final class TickingMetricsSampler: SystemMetricsSampling {
    private var tick = 0

    func sampleOnce() async -> SystemMetricsSnapshot {
        tick += 1
        let offset = tick
        return SystemMetricsSnapshot(
            thermalState: .nominal,
            smc: .unavailable,
            cpu: .unavailable,
            memory: .unavailable,
            loadAverage: .zero,
            processes: (1...40).map {
                ProcessRow(
                    pid: pid_t($0),
                    name: "process-\($0)" + String(repeating: "x", count: ($0 + offset) % 7),
                    path: nil,
                    cpuPercent: Double(($0 * 7 + offset * 13) % 100),
                    physFootprintBytes: UInt64(($0 + offset) % 40 + 1) * 1_000_000
                )
            },
            sampledAt: Date()
        )
    }
}

/// #0601: each status-view Pane, hosted alone (root tier) and inside the
/// production session detail tree (split tier), reaches a layout fixed
/// point across Pane sizes, scroller styles and sampler ticks.
@MainActor
struct StatusPaneLayoutConvergenceTests {

    private struct StatusFixture {
        let name: String
        let view: AnyView
        let tick: @MainActor () async -> Void
        let ready: @MainActor () -> Bool
        let tearDown: @MainActor () -> Void
    }

    private func releaseTerminals(of pane: PaneRuntime) {
        for tab in pane.tabs {
            TerminalHostStore.shared.releaseTerminalView(forTabID: tab.id)
        }
    }

    private func systemMetricsFixture() -> StatusFixture {
        let content = SystemMetricsPaneContent()
        content.samplerFactory = { TickingMetricsSampler() }
        let pane = PaneRuntime(kind: .systemMetrics, contentFactory: { _ in content })
        let tree = SplitTree(root: .leaf(pane))
        return StatusFixture(
            name: "System Metrics",
            view: AnyView(SplitContainerView(tree: tree).environment(\.windowID, WindowID())),
            tick: { await content.refreshNow() },
            ready: { content.snapshot.sampledAt != nil },
            tearDown: {
                content.tearDown()
                self.releaseTerminals(of: pane)
            }
        )
    }

    private func processStatusFixture(exited: Bool) -> StatusFixture {
        var sample = 0
        let content = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { _ in
                sample += 1
                if exited, sample > 1 { return .failure(.processNotFound) }
                return .success(ProcessInspector.CoreMetrics(
                    residentBytes: UInt64(sample) * 3_000_000,
                    physFootprintBytes: UInt64(sample % 5 + 1) * 2_000_000,
                    threadCount: sample % 9 + 1,
                    openFileCount: sample % 13,
                    cpuTicksUser: UInt64(sample) * 1_000_000,
                    cpuTicksSystem: UInt64(sample) * 500_000
                ))
            },
            clock: TestClock()
        )
        let pane = PaneRuntime(kind: .processStatus, contentFactory: { _ in content })
        let tree = SplitTree(root: .leaf(pane))
        return StatusFixture(
            name: exited ? "Process Status (exited)" : "Process Status (running)",
            view: AnyView(SplitContainerView(tree: tree).environment(\.windowID, WindowID())),
            tick: { content.sampleNowForTesting() },
            ready: {
                if exited { content.sampleNowForTesting() }
                return content.snapshot != nil && (!exited || content.runState == .exited)
            },
            tearDown: {
                content.tearDown()
                self.releaseTerminals(of: pane)
            }
        )
    }

    private func lmStudioFixture() -> StatusFixture {
        let content = LMStudioDashboardPaneContent()
        let pane = PaneRuntime(kind: .lmStudioDashboard, isSessionSelected: false, contentFactory: { _ in content })
        let tree = SplitTree(root: .leaf(pane))
        return StatusFixture(
            name: "LM Studio (disconnected)",
            view: AnyView(SplitContainerView(tree: tree).environment(\.windowID, WindowID())),
            tick: {},
            ready: { true },
            tearDown: {
                content.tearDown()
                self.releaseTerminals(of: pane)
            }
        )
    }

    private func gitStatusContent() -> GitStatusPaneContent {
        GitStatusPaneContent(
            directoryPath: "/tmp/example-repo",
            scanner: TickingGitScanner(),
            watcherFactory: { _, _ in InertGitWatcher() },
            clock: TestClock()
        )
    }

    private func gitStatusFixture() -> StatusFixture {
        let content = gitStatusContent()
        content.setUp(visible: true)
        return StatusFixture(
            name: "Git Status",
            view: AnyView(
                GitStatusPaneView(content: content, initiallyExpandsFileGroups: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            ),
            tick: { content.refreshNow() },
            ready: {
                guard case .snapshot(let snapshot) = content.state else { return false }
                if content.selectedEntryID == nil, let entry = snapshot.unstaged.first {
                    content.selectEntry(entry, staged: false)
                }
                return content.diffText?.isEmpty == false
            },
            tearDown: { content.tearDown() }
        )
    }

    private static func isHostingScrollView(_ view: NSView) -> Bool {
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            if NSStringFromClass(current).contains("HostingScrollView") { return true }
            cls = class_getSuperclass(current)
        }
        return false
    }

    private func hostingScrollViewCount(_ probe: LayoutConvergenceProbe) -> Int {
        probe.allViews().filter { $0 is NSScrollView && Self.isHostingScrollView($0) }.count
    }

    /// The vertical scroll view's document height at `width`, read once
    /// with a tall Pane so the content is not clipped.
    private func idealContentHeight(_ probe: LayoutConvergenceProbe, width: CGFloat) async -> CGFloat {
        probe.resize(to: CGSize(width: width, height: 2400))
        _ = await probe.settle()
        let heights = probe.scrollViews().compactMap { $0.documentView?.frame.height }
        return heights.max() ?? 400
    }

    private func sweep(
        _ fixture: StatusFixture,
        widths: [CGFloat],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let probe = LayoutConvergenceProbe(fixture.view, size: CGSize(width: 480, height: 600))
        defer {
            fixture.tearDown()
            probe.window.close()
        }
        await probe.pump(until: fixture.ready, sourceLocation: sourceLocation)
        var worst = 0
        for width in widths {
            let ideal = await idealContentHeight(probe, width: width)
            let heights = [-24, -8, -1, 0, 1, 8, 24].map { max(80, ideal + CGFloat($0)) } + [1600]
            for height in heights {
                for style in [NSScroller.Style.legacy, .overlay] {
                    probe.resize(to: CGSize(width: width, height: height))
                    _ = await probe.settle()
                    probe.forceScrollerStyle(style)
                    let settled = await probe.settle()
                    worst = max(worst, settled.postNeedsUpdateConstraintsCalls)
                    #expect(settled.converged, "\(fixture.name) root tier \(width)x\(height) \(style == .legacy ? "legacy" : "overlay"): \(settled)", sourceLocation: sourceLocation)
                    for tick in 1...3 {
                        await fixture.tick()
                        let ticked = await probe.settle()
                        worst = max(worst, ticked.postNeedsUpdateConstraintsCalls)
                        #expect(ticked.converged, "\(fixture.name) root tier \(width)x\(height) \(style == .legacy ? "legacy" : "overlay") tick \(tick): \(ticked)", sourceLocation: sourceLocation)
                    }
                }
            }
        }
        Self.record(fixture.name, worst: worst)
    }

    /// Calibration output only: the most window update-constraints
    /// requests one settle made, printed for `## Verification`.
    private static func record(_ name: String, worst: Int) {
        print("LayoutConvergenceProbe \(name): worst requests per settle \(worst)")
    }

    /// Narrow, middle and wide Pane widths. Every height and both scroller
    /// styles run at each, which keeps a test to a few seconds.
    private static let widths: [CGFloat] = [200, 400, 720]

    // MARK: - Root tier

    @Test func systemMetricsPaneConverges() async {
        await sweep(systemMetricsFixture(), widths: Self.widths)
    }

    @Test func processStatusPaneConverges() async {
        await sweep(processStatusFixture(exited: false), widths: Self.widths)
        await sweep(processStatusFixture(exited: true), widths: Self.widths)
    }

    @Test func lmStudioDashboardPaneConverges() async {
        await sweep(lmStudioFixture(), widths: Self.widths)
    }

    @Test func gitStatusPaneConverges() async {
        let fixture = gitStatusFixture()
        let probe = LayoutConvergenceProbe(fixture.view, size: CGSize(width: 600, height: 800))
        await probe.pump(until: fixture.ready)
        _ = await probe.settle()
        #expect(hostingScrollViewCount(probe) == 2, "the diff peek's horizontal ScrollView did not render")
        probe.window.close()
        await sweep(fixture, widths: Self.widths)
    }

    @Test func gitStatusDiffPeekRendersOnlyWhenExpanded() async {
        let content = gitStatusContent()
        content.setUp(visible: true)
        let probe = LayoutConvergenceProbe(
            GitStatusPaneView(content: content).frame(maxWidth: .infinity, maxHeight: .infinity),
            size: CGSize(width: 600, height: 800)
        )
        defer {
            content.tearDown()
            probe.window.close()
        }
        await probe.pump(until: {
            guard case .snapshot(let snapshot) = content.state else { return false }
            if content.selectedEntryID == nil, let entry = snapshot.unstaged.first {
                content.selectEntry(entry, staged: false)
            }
            return content.diffText?.isEmpty == false
        })
        _ = await probe.settle()
        #expect(hostingScrollViewCount(probe) == 1)
    }

    // MARK: - Split tier

    /// All four status kinds inside the production session detail tree,
    /// next to terminal Panes, across window sizes, scroller styles, ticks
    /// and Session switches.
    @Test func statusPanesConvergeInTheSessionDetailTree() async throws {
        let store = AppStateStore()
        let windowRuntime = store.windows[0]
        let metrics = SystemMetricsPaneContent()
        metrics.samplerFactory = { TickingMetricsSampler() }
        var processSample = 0
        let process = ProcessStatusPaneContent(
            target: .pinned(getpid()),
            tabLookup: { _ in nil },
            coreMetricsProvider: { _ in
                processSample += 1
                return .success(ProcessInspector.CoreMetrics(
                    residentBytes: UInt64(processSample) * 3_000_000,
                    physFootprintBytes: UInt64(processSample % 5 + 1) * 2_000_000,
                    threadCount: processSample % 9 + 1,
                    openFileCount: processSample % 13,
                    cpuTicksUser: UInt64(processSample) * 1_000_000,
                    cpuTicksSystem: UInt64(processSample) * 500_000
                ))
            },
            clock: TestClock()
        )
        let lmStudio = LMStudioDashboardPaneContent()
        let git = gitStatusContent()

        let first = try #require(windowRuntime.sessions.first?.tree.allPanes.first?.id)
        let metricsSplit = store.splitPane(id: first, direction: .horizontal, kind: .systemMetrics, contentFactory: { _ in metrics })
        let metricsID = try #require(metricsSplit)
        store.splitPane(id: metricsID, direction: .vertical, kind: .processStatus, contentFactory: { _ in process })
        let second = windowRuntime.addSession()
        let secondPane = try #require(second.tree.allPanes.first?.id)
        let lmSplit = store.splitPane(id: secondPane, direction: .horizontal, kind: .lmStudioDashboard, contentFactory: { _ in lmStudio })
        let lmID = try #require(lmSplit)
        store.splitPane(id: lmID, direction: .vertical, kind: .gitStatus, path: "/tmp/example-repo", contentFactory: { _ in git })
        windowRuntime.selectSession(at: 0)

        let probe = LayoutConvergenceProbe(
            NavigationSplitView {
                SessionSidebarView(store: store, windowRuntime: windowRuntime)
            } detail: {
                SessionDetailView(store: store, windowRuntime: windowRuntime)
            }
            .environment(\.appStateStore, store)
            .environment(\.themeChrome, store.themeChrome),
            size: CGSize(width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        defer {
            for session in windowRuntime.sessions {
                for pane in session.tree.allPanes {
                    releaseTerminals(of: pane)
                    pane.content?.tearDown()
                }
            }
            TerminalHostStore.shared.releaseHost(forWindowID: windowRuntime.id)
            probe.window.close()
        }
        await probe.pump(until: { metrics.snapshot.sampledAt != nil && process.snapshot != nil })

        var worst = 0
        for size in [CGSize(width: 760, height: 480), CGSize(width: 1000, height: 640), CGSize(width: 1300, height: 900)] {
            for style in [NSScroller.Style.legacy, .overlay] {
                for sessionIndex in 0..<2 {
                    windowRuntime.selectSession(at: sessionIndex)
                    probe.resize(to: size)
                    _ = await probe.settle()
                    probe.forceScrollerStyle(style)
                    let settled = await probe.settle()
                    worst = max(worst, settled.postNeedsUpdateConstraintsCalls)
                    #expect(settled.converged, "split tier \(size) Session \(sessionIndex) \(style == .legacy ? "legacy" : "overlay"): \(settled)")
                    for tick in 1...3 {
                        await metrics.refreshNow()
                        process.sampleNowForTesting()
                        git.refreshNow()
                        let ticked = await probe.settle()
                        worst = max(worst, ticked.postNeedsUpdateConstraintsCalls)
                        #expect(ticked.converged, "split tier \(size) Session \(sessionIndex) tick \(tick): \(ticked)")
                    }
                }
            }
        }
        Self.record("split tier", worst: worst)
    }
}
