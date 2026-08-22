// SystemMetricsPaneView.swift

import AppKit
import SwiftUI

/// The `system-metrics` Pane kind's real content (#0314 phase 2), replacing
/// `PaneContentPlaceholderView` for `pane.kind == .systemMetrics`. Layout
/// follows `docs/design/system-metrics-view.md` §7 / the companion HTML
/// mockup: thermal chip, numeric CPU-temperature/fan tiles, per-core CPU
/// bars, a system memory bar, load average, and the full process list.
///
/// Reads `content.snapshot`, replaced wholesale by `SystemMetricsPaneContent`
/// on every 1-second tick while the pane is visible — this view has no
/// timer, watcher, or state of its own beyond transient UI state (sort
/// order), matching `docs/pane-view-lifecycle.md` §5's "the conformer is
/// model-owned" split between model and view.
public struct SystemMetricsPaneView: View {
    private enum SortField: String, CaseIterable {
        case name = "Name"
        case pid = "PID"
        case cpu = "CPU"
        case memory = "Memory"
    }

    let content: SystemMetricsPaneContent

    @State private var sortField: SortField = .memory
    @State private var sortAscending = false

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
        HStack(spacing: 10) {
            thermalChip
            pressureChip
            Spacer(minLength: 8)
            Text("Refreshing every 1s")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                content.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .accessibilityIdentifier("system-metrics-refresh-button")
        }
    }

    private var thermalChip: some View {
        Label(thermalStateLabel, systemImage: "thermometer.medium")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(thermalStateColor))
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
        Text("Memory pressure: \(pressureLabel)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(pressureColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .strokeBorder(pressureColor.opacity(0.4))
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            )
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
        case .normal: return .secondary
        case .warn: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
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
                sub: content.snapshot.smc.cpuTemperatureKey.map { "SMC key \($0)" } ?? "Not available on this Mac"
            )
            metricTile(
                label: "Fan",
                value: content.snapshot.smc.fanRPM.map(SystemMetricsFormatting.rpm) ?? "\u{2014}",
                sub: content.snapshot.smc.fanCount.map { "\($0) fan\($0 == 1 ? "" : "s")" } ?? "Not available on this Mac"
            )
        }
    }

    private func metricTile(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Text(sub)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - Per-core CPU bars

    private var coreBarsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PER-CORE UTILIZATION")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array((content.snapshot.cpu.perCorePercent ?? []).enumerated()), id: \.offset) { _, percent in
                    coreBar(percent: percent)
                }
            }
            .frame(height: 34)
        }
    }

    private func coreBar(percent: Double) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(percent >= 80 ? Color.orange : Color.accentColor)
                    .frame(height: max(1, proxy.size.height * CGFloat(min(max(percent, 0), 100)) / 100))
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
                    Rectangle().fill(Color.accentColor)
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

            HStack(spacing: 14) {
                memoryLegendItem(color: .accentColor, label: "Active", bytes: memory.activeBytes)
                memoryLegendItem(color: .purple, label: "Wired", bytes: memory.wiredBytes)
                memoryLegendItem(color: .orange, label: "Compressed", bytes: memory.compressedBytes)
                memoryLegendItem(color: .secondary.opacity(0.3), label: "Free", bytes: memory.freeBytes)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    private func memoryLegendItem(color: Color, label: String, bytes: UInt64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(SystemMetricsFormatting.bytes(bytes))")
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

    private var sortedRows: [ProcessRow] {
        let rows = content.snapshot.processes
        let sorted: [ProcessRow]
        switch sortField {
        case .name:
            sorted = rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            sorted = rows.sorted { $0.pid < $1.pid }
        case .cpu:
            sorted = rows.sorted { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
        case .memory:
            sorted = rows.sorted { ($0.physFootprintBytes ?? 0) < ($1.physFootprintBytes ?? 0) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

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
        HStack(spacing: 8) {
            sortHeaderButton(.name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(.pid, alignment: .trailing).frame(width: 60, alignment: .trailing)
            sortHeaderButton(.cpu, alignment: .trailing).frame(width: 56, alignment: .trailing)
            sortHeaderButton(.memory, alignment: .trailing).frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
    }

    private func sortHeaderButton(_ field: SortField, alignment: Alignment) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(field.rawValue.uppercased())
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var processList: some View {
        List(sortedRows) { row in
            processRow(row)
                .contextMenu { processContextMenu(for: row) }
        }
        .listStyle(.plain)
        .frame(minHeight: 260, idealHeight: 420, maxHeight: 460)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func processRow(_ row: ProcessRow) -> some View {
        let denied = row.cpuPercent == nil && row.physFootprintBytes == nil
        return HStack(spacing: 8) {
            Text(row.name)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.pid)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            Text(row.cpuPercent.map { SystemMetricsFormatting.percent($0) } ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(row.physFootprintBytes.map(SystemMetricsFormatting.bytes) ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(denied ? .tertiary : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.visible)
    }

    @ViewBuilder
    private func processContextMenu(for row: ProcessRow) -> some View {
        Button("Copy PID") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("\(row.pid)", forType: .string)
        }
        Button("Reveal Executable in Finder") {
            guard let path = row.path else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(row.path == nil)
    }
}
