// LMStudioDashboardView.swift

import AppKit
import SwiftUI

/// The `lm-studio-dashboard` pane kind's real content
/// (`docs/design/lmstudio-dashboard-view.md`), replacing
/// `PaneContentPlaceholderView` for this one kind. Purely a renderer over
/// `LMStudioDashboardPaneContent`'s `@Observable` state — all data
/// collection, polling, and subprocess management lives on the model side
/// (`docs/pane-view-lifecycle.md` §5's "model-owned, not view-owned").
///
/// No side-effecting hook of its own (no `.task`, no `onAppear`): `setUp`
/// now runs inside `PaneRuntime.init` itself, via the injectable
/// `contentFactory` (rebased onto #0314's central resolution of this
/// exact question — a `.task`-driven `setUp` here contradicted
/// `docs/pane-view-lifecycle.md`'s "at Pane creation" requirement and made
/// its `.rejected`-event logging routine rather than a real bug signal).
/// Hide/show/teardown are driven by `WindowRuntime.hidePane`/`showPane`/
/// the pane-removal paths, never by this view's own lifecycle — matching
/// `SystemMetricsPaneView`'s identical shape.
struct LMStudioDashboardView: View {
    @Bindable var content: LMStudioDashboardPaneContent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                switch content.connectionState {
                case .notInstalled:
                    notInstalledBanner
                case .unreachable:
                    unreachableBanner
                default:
                    EmptyView()
                }
                loadedModelsSection
                if content.connectionState == .connected || content.connectionState == .reconnecting {
                    liveRequestsSection
                    throughputSection
                    engineErrorsSection
                    if content.promptInspectorEnabled {
                        inspectorSection
                    }
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("lmstudio-dashboard")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            connectionPill
            Spacer(minLength: 8)
            Toggle("Prompt Inspector", isOn: $content.promptInspectorEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("lmstudio-prompt-inspector-toggle")
            Button {
                content.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .accessibilityIdentifier("lmstudio-refresh-button")
        }
    }

    private var connectionPill: some View {
        let (text, color): (String, Color) = {
            switch content.connectionState {
            case .checking: return ("Checking…", .secondary)
            case .notInstalled: return ("LM Studio CLI not found", .orange)
            case .unreachable: return ("No server", .red)
            case .reconnecting: return ("Reconnecting…", .yellow)
            case .connected: return ("Connected", .green)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("lmstudio-connection-pill.\(content.connectionState.rawValue)")
    }

    // MARK: - Degraded states

    private var notInstalledBanner: some View {
        Text("The `lms` CLI was not found on this Mac. Loaded-model info still polls over HTTP, but the live prediction feed and Engine Errors panel need the CLI to stream `lms log stream`.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var unreachableBanner: some View {
        Text("No LM Studio server reachable at localhost:1234. This pane only observes a server on the same Mac Batty is running on — a remote server (e.g. a Mac mini) is not supported in this phase.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: - Loaded models

    private var loadedModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loaded Models").font(.headline)
            if content.loadedModels.isEmpty {
                Text("No models loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.loadedModels) { model in
                    loadedModelRow(model)
                }
            }
            if content.catalogCount > 0 {
                Text("\(content.catalogCount) more available, not loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadedModelRow(_ model: LMStudioLoadedModelSummary) -> some View {
        let ps = content.psByIdentifier[model.instanceID]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.displayName).font(.callout.weight(.semibold))
                if let ps {
                    statusPill(ps: ps)
                }
                Spacer()
                if let sizeBytes = model.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .memory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(subtitle(for: model, ps: ps))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("lmstudio-model-row.\(model.instanceID)")
    }

    private func statusPill(ps: LMStudioPsEntry) -> some View {
        Text(ps.isGenerating ? "Generating" : "Idle")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ps.isGenerating ? Color.green.opacity(0.25) : Color.gray.opacity(0.2), in: Capsule())
    }

    private func subtitle(for model: LMStudioLoadedModelSummary, ps: LMStudioPsEntry?) -> String {
        var parts: [String] = []
        if let publisher = model.publisher { parts.append(publisher) }
        if let params = model.paramsString { parts.append(params) }
        if let quant = model.quantizationName { parts.append(quant) }
        if let context = model.contextLength { parts.append("ctx \(context)") }
        if let parallel = model.parallel { parts.append("parallel \(parallel)") }
        let device = ps?.deviceIdentifier ?? "Local"
        parts.append("device \(device)")
        if let ttlMs = ps?.ttlMs {
            parts.append("TTL \(ttlMs / 1000)s")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Live requests

    private var liveRequestsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live Requests").font(.headline)
            if !content.inFlight.isEmpty {
                ForEach(content.inFlight) { request in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(request.modelIdentifier).font(.caption.weight(.medium))
                        Spacer()
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Paired by model and arrival order — no request ID exists. With more than one prediction running on the same model, this pane can't always tell which reply belongs to which request — and has been observed to get it wrong, not just be unable to confirm it.")
                    }
                    .accessibilityIdentifier("lmstudio-inflight-row")
                }
            }
            if content.recentCompletions.isEmpty {
                Text("No completions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.recentCompletions.prefix(30)) { record in
                    completionRow(record)
                }
            }
        }
    }

    private func completionRow(_ record: LMStudioCompletionRecord) -> some View {
        HStack(spacing: 8) {
            Text(record.completedAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(record.modelIdentifier)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let tokPerSec = record.stats?.tokensPerSecond {
                Text(String(format: "%.0f tok/s", tokPerSec))
                    .font(.caption)
            }
            if let ttft = record.stats?.timeToFirstTokenSec {
                Text(String(format: "TTFT %.2fs", ttft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let stopReason = record.stats?.stopReason {
                Text(stopReason)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if let pressure = record.contextPressure {
                Text("\(Int(pressure * 100))% ctx")
                    .font(.caption2)
                    .foregroundStyle(pressure > 0.9 ? .red : .secondary)
            }
        }
        .contextMenu {
            Button("Copy Model Identifier") {
                copyToPasteboard(record.modelIdentifier)
            }
            Button("Copy Stats as JSON") {
                copyToPasteboard(statsJSON(record.stats))
            }
        }
        .accessibilityIdentifier("lmstudio-completion-row.\(record.id.uuidString)")
    }

    private func statsJSON(_ stats: LMStudioPredictionStats?) -> String {
        guard let stats,
              let data = try? JSONEncoder().encode(stats),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    // MARK: - Throughput summary

    private var throughputSection: some View {
        let samples = content.recentCompletions.compactMap(\.stats?.tokensPerSecond)
        let average = samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
        var stopReasonTally: [String: Int] = [:]
        for record in content.recentCompletions {
            guard let reason = record.stats?.stopReason else { continue }
            stopReasonTally[reason, default: 0] += 1
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Throughput").font(.headline)
            if let average {
                Text(String(format: "avg %.1f tok/s over last %d completions", average, samples.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No throughput data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !stopReasonTally.isEmpty {
                Text(stopReasonTally.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }.joined(separator: "  ·  "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Engine errors

    private var engineErrorsSection: some View {
        DisclosureGroup("Engine Errors & Warnings (\(content.engineErrors.count))") {
            if content.engineErrors.isEmpty {
                Text("None.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.engineErrors.prefix(20)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(entry.level ?? "?") · \(entry.engineName ?? "engine")")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(entry.message ?? "")
                            .font(.caption2)
                    }
                }
            }
        }
        .font(.callout)
    }

    // MARK: - Prompt Inspector

    private var inspectorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt Inspector is ON — showing raw prompt and completion text for the last \(LMStudioDashboardPaneContent.inspectorCap) predictions only")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if content.inspectorEntries.isEmpty {
                Text("No captured predictions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(content.inspectorEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.modelIdentifier).font(.caption.weight(.semibold))
                        if let prompt = entry.prompt {
                            Text("Prompt: \(prompt)").font(.caption2).lineLimit(6)
                        }
                        if let completion = entry.completion {
                            Text("Completion: \(completion)").font(.caption2).lineLimit(6)
                        }
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}
