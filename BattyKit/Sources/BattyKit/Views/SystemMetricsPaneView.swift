// SystemMetricsPaneView.swift

import AppKit
import SwiftUI

/// The `system-metrics` Pane kind's real content (#0314 phase 2), replacing
/// `PaneContentPlaceholderView` for `pane.kind == .systemMetrics`. Layout
/// follows `docs/design/system-metrics-view.md` §7 / the companion HTML
/// mockup: thermal chip, numeric CPU-temperature/fan tiles, per-core CPU
/// bars, a system memory bar, load average, and the full process list.
///
/// Reads `content.snapshot` and `content.sortedProcesses`, replaced by
/// `SystemMetricsPaneContent` on every 1-second tick while the pane is
/// visible — this view has no timer, watcher, or state of its own (the sort
/// order lives in the content too), matching `docs/pane-view-lifecycle.md` §5's "the conformer is
/// model-owned" split between model and view.
public struct SystemMetricsPaneView: View {
    @Environment(\.themeChrome) private var themeChrome

    let content: SystemMetricsPaneContent

    private var colors: SystemMetricsColors {
        SystemMetricsColors(palette: themeChrome?.palette)
    }

    public init(content: SystemMetricsPaneContent) {
        self.content = content
    }

    public var body: some View {
        ScrollView {
            // Review round 1 (#0314): `.empty`'s zero-valued memory/load
            // figures and `.nominal` thermal state used to render as a
            // full, plausible-looking dashboard before the first real
            // sample ever landed -- `sampledAt` (whose entire job is
            // distinguishing "no sample yet" from "sampled") was never
            // read by this view. A first-sample gate is the fix: nothing
            // that looks like a measurement renders until one actually
            // exists.
            if content.snapshot.sampledAt == nil {
                waitingForFirstSample
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    statusRow
                    metricsGrid
                    coreBarsSection
                    memorySection
                    loadAverageSection
                    processSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("system-metrics-pane")
    }

    private var waitingForFirstSample: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Sampling system metrics\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding()
        .accessibilityIdentifier("system-metrics-waiting")
    }

    // MARK: - Status row

    private var statusRow: some View {
        let refresh = Button {
            Task { await content.refreshNow() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh now")
        .accessibilityIdentifier("system-metrics-refresh-button")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                thermalChip
                pressureChip
                Spacer(minLength: 8)
                Text("Refreshing every 1s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                refresh
            }
            HStack(spacing: 8) {
                thermalChip
                pressureChip
                Spacer(minLength: 8)
                refresh
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    thermalChip
                    pressureChip
                }
                Spacer(minLength: 8)
                refresh
            }
        }
    }

    private var thermalChip: some View {
        StatusBadge(text: thermalStateLabel, systemImage: "thermometer.medium", color: thermalStateColor)
    }

    private var thermalStateLabel: String {
        switch content.snapshot.thermalState {
        case .nominal: return "Thermal: Nominal"
        case .fair: return "Thermal: Fair"
        case .serious: return "Thermal: Serious"
        case .critical: return "Thermal: Critical"
        @unknown default: return "Thermal: Unknown"
        }
    }

    private var thermalStateColor: Color {
        switch content.snapshot.thermalState {
        case .nominal: return .green
        case .fair: return .blue
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    private var pressureChip: some View {
        StatusBadge(text: "Memory pressure: \(pressureLabel)", color: pressureColor)
    }

    private var pressureLabel: String {
        switch content.snapshot.memory.pressureLevel {
        case .normal: return "Normal"
        case .warn: return "Warn"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    private var pressureColor: Color {
        switch content.snapshot.memory.pressureLevel {
        case .normal: return .green
        case .warn: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinWidth), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            metricTile(
                label: "CPU (aggregate)",
                // Review round 1 (#0314): aggregatePercent is nil,
                // not a fabricated 0, on the no-baseline-yet tick --
                // render "-", never a number that looks measured.
                value: content.snapshot.cpu.aggregatePercent.map { SystemMetricsFormatting.percent($0) } ?? "\u{2014}",
                sub: "\(content.snapshot.cpu.coreCount) cores"
            )
            metricTile(label: "Memory used", value: SystemMetricsFormatting.bytes(content.snapshot.memory.usedBytes), sub: "of \(SystemMetricsFormatting.bytes(content.snapshot.memory.totalBytes))")
            metricTile(label: "Compressed", value: SystemMetricsFormatting.bytes(content.snapshot.memory.compressedBytes), sub: "never counted as \u{201C}free\u{201D}")
            metricTile(
                label: "CPU Temperature",
                value: content.snapshot.smc.cpuTemperatureCelsius.map(SystemMetricsFormatting.celsius) ?? "\u{2014}",
                sub: content.snapshot.smc.cpuTemperatureDetail ?? (content.snapshot.smc.unavailableReason?.copy ?? "Not available on this Mac")
            )
            metricTile(
                label: "Fan",
                value: content.snapshot.smc.fanRPM.map(SystemMetricsFormatting.rpm) ?? "\u{2014}",
                sub: content.snapshot.smc.fanCount.map { "\($0) fan\($0 == 1 ? "" : "s")" } ?? (content.snapshot.smc.fanUnavailableReason?.fanCopy ?? "Not available on this Mac")
            )
        }
    }

    private static let tileMinWidth: CGFloat = 128

    private func metricTile(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(.callout, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }

    // MARK: - Per-core CPU bars

    private var coreBarsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PER-CORE UTILIZATION")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            HStack(alignment: .bottom, spacing: 3) {
                if let perCore = content.snapshot.cpu.perCorePercent {
                    ForEach(Array(perCore.enumerated()), id: \.offset) { _, percent in
                        coreBar(percent: percent)
                    }
                } else {
                    ForEach(0..<max(content.snapshot.cpu.coreCount, 1), id: \.self) { _ in
                        coreBar(percent: nil)
                    }
                }
            }
            .frame(height: 34)
        }
    }

    private func coreBar(percent: Double?) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let percent {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(percent >= 80 ? Color.orange : colors.accent)
                        .frame(height: max(1, proxy.size.height * CGFloat(min(max(percent, 0), 100)) / 100))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Memory bar

    private var memorySection: some View {
        let memory = content.snapshot.memory
        let total = max(memory.totalBytes, 1)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(colors.accent)
                        .frame(width: proxy.size.width * CGFloat(memory.activeBytes) / CGFloat(total))
                    Rectangle().fill(Color.purple)
                        .frame(width: proxy.size.width * CGFloat(memory.wiredBytes) / CGFloat(total))
                    Rectangle().fill(Color.orange)
                        .frame(width: proxy.size.width * CGFloat(memory.compressedBytes) / CGFloat(total))
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 4) {
                memoryLegendItem(color: colors.accent, label: "Active", bytes: memory.activeBytes)
                memoryLegendItem(color: .purple, label: "Wired", bytes: memory.wiredBytes)
                memoryLegendItem(color: .orange, label: "Compressed", bytes: memory.compressedBytes)
                memoryLegendItem(color: .secondary.opacity(0.3), label: "Free", bytes: memory.freeBytes)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func memoryLegendItem(color: Color, label: String, bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(SystemMetricsFormatting.bytes(bytes))")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Load average

    private var loadAverageSection: some View {
        HStack(spacing: 18) {
            loadItem(label: "Load 1m", value: content.snapshot.loadAverage.oneMinute)
            loadItem(label: "Load 5m", value: content.snapshot.loadAverage.fiveMinute)
            loadItem(label: "Load 15m", value: content.snapshot.loadAverage.fifteenMinute)
        }
    }

    private func loadItem(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(SystemMetricsFormatting.loadAverage(value))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }

    // MARK: - Process list

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PROCESSES")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(content.snapshot.processes.count) total")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            processListHeader
            processList
        }
    }

    private var processListHeader: some View {
        HStack(spacing: Row.columnSpacing) {
            sortHeaderButton(.name).frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(.pid).frame(width: Row.pidColumnWidth, alignment: .trailing)
            sortHeaderButton(.cpu).frame(width: Row.cpuColumnWidth, alignment: .trailing)
            sortHeaderButton(.memory).frame(width: Row.memoryColumnWidth, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
    }

    private typealias Row = SystemMetricsProcessRowView

    private func sortHeaderButton(_ field: ProcessRowSort.Field) -> some View {
        let sort = content.processSort
        return Button {
            content.setProcessSort(content.processSort.toggled(for: field))
        } label: {
            HStack(spacing: 2) {
                Text(field.rawValue.uppercased())
                    .lineLimit(1)
                if sort.field == field {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Rows scroll with the Pane's one `ScrollView`. A `List` nested here
    /// (its own `NSScrollView` and `NSTableView`) made hundreds of window
    /// update-constraints requests on every 1 s tick (#0606).
    private var processList: some View {
        LazyVStack(spacing: 0) {
            ForEach(content.sortedProcesses) { row in
                Row(row: row, colors: colors).equatable()
            }
        }
        .background(colors.tableBackground ?? Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(colors.border))
    }
}
