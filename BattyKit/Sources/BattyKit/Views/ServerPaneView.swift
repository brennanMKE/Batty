// ServerPaneView.swift

import SwiftUI

/// The Server Pane (#0648, `docs/design/server-pane-view.md`). Reads
/// `ServerPaneContent` only; the buttons are the only writes.
struct ServerPaneView: View {
    let content: ServerPaneContent
    let paneID: UUID

    private var kind: ServerBackendKind { content.backend.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let reason = content.stopRefusal {
                Text("Stop unavailable: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("server-pane-stop-refused")
            }
            if let error = content.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("server-pane-error")
            }
            Divider()
            facts
            if content.statsVisible || content.statsUnavailableReason != nil {
                Divider()
                stats
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("server-pane.\(paneID.uuidString)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(toneColor).frame(width: 9, height: 9)
                Text(ServerPaneDisplay.stateText(content.state, isResponding: content.isResponding, kind: kind))
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("server-pane-state")
            }
            Text(content.url.absoluteString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("server-pane-url")
            if let status = content.httpStatus {
                Text(String(status)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Open in Browser") { content.openInBrowser() }
                .accessibilityIdentifier("server-pane-open-browser")
            if ServerPaneDisplay.showsRestart(canRestart: content.canRestart) {
                Button("Restart") { content.restart() }
                    .accessibilityIdentifier("server-pane-restart")
            }
            if ServerPaneDisplay.showsStop(content.state, canStop: content.canStop, kind: kind) {
                Button("Stop") { content.stop() }
                    .accessibilityIdentifier("server-pane-stop")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toneColor: Color {
        switch ServerPaneDisplay.tone(content.state, isResponding: content.isResponding) {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .neutral: .gray
        }
    }

    @ViewBuilder
    private var facts: some View {
        if kind == .inApp {
            servingFactsGrid
        } else {
            processFacts
        }
    }

    private var servingFactsGrid: some View {
        let facts = content.servingFacts
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                label("Root")
                Text(facts?.root ?? content.backend.workingDirectory ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("server-pane-root")
            }
            GridRow {
                label("Requests")
                Text(facts.map { String($0.requestCount) } ?? "—").accessibilityIdentifier("server-pane-requests")
            }
            GridRow {
                label("Live reload")
                Text(ServerPaneDisplay.liveReloadText(facts)).accessibilityIdentifier("server-pane-live-reload")
            }
            GridRow {
                label("Last change")
                if let date = facts?.lastChangeAt {
                    Text(date, style: .relative)
                } else {
                    Text("—")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var processFacts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                label("PID")
                Text(content.listenerPid.map(String.init) ?? "—").accessibilityIdentifier("server-pane-pid")
                label("Uptime")
                if let start = content.metrics?.startDate {
                    Text(start, style: .relative)
                } else {
                    Text("—")
                }
            }
            GridRow {
                label("CPU")
                Text(content.metrics?.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "—")
                label("Memory")
                Text(content.metrics.map { ByteCountFormatter.string(fromByteCount: Int64($0.footprintBytes), countStyle: .memory) } ?? "—")
            }
            GridRow {
                label("Exit")
                Text(content.lastExitCode.map(String.init) ?? "—")
                label("Command")
                Text(content.backend.command ?? content.recoveredCommandLine ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let host = content.nonLoopbackStatsHost {
                Text("Stats from \(host)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Stats").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = content.statsUnavailableReason {
                Text("Stats unavailable: \(reason)").foregroundStyle(.secondary)
            } else {
                let history = content.stats
                let changed = history.changedKeys
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(history.latest.numbers.keys.sorted(), id: \.self) { key in
                            HStack(spacing: 8) {
                                Text(key).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                                Text(Self.format(history.latest.numbers[key] ?? 0)).frame(minWidth: 80, alignment: .trailing)
                                if changed.contains(key) {
                                    ServerStatSparkline(values: history.series[key] ?? []).frame(width: 90, height: 14)
                                }
                            }
                        }
                        ForEach(history.latest.texts.keys.sorted(), id: \.self) { key in
                            HStack(spacing: 8) {
                                Text(key).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                                Text(history.latest.texts[key] ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("server-pane-stats")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.3g", value)
    }
}
