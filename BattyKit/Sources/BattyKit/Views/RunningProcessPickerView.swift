// RunningProcessPickerView.swift

import SwiftUI

/// Popover content for "Pick a Running Process…". Owns the filter query,
/// highlight and follow toggle as view-local `@State` so they survive the
/// parent's once-a-second re-evaluation; filtering the cached array is cheap
/// enough to repeat. `processes` is the array fetched once when the popover
/// was opened.
struct RunningProcessPickerView: View {
    let processes: [ProcessInspector.RunningProcess]
    let onPick: (ProcessInspector.RunningProcess, _ followByName: Bool) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightedPid: pid_t?
    @State private var followByName = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        let rows = ProcessPickerFilter.apply(query, to: processes)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by name or PID", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .accessibilityIdentifier("process-status.picker.filter-field")
                    .onKeyPress(.upArrow) { moveHighlight(-1, in: rows); return .handled }
                    .onKeyPress(.downArrow) { moveHighlight(1, in: rows); return .handled }
                    .onKeyPress(.return) { pickHighlighted(in: rows); return .handled }
                    .onKeyPress(.escape) { escape(); return .handled }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                Text("No processes match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("process-status.picker.empty")
            } else {
                ScrollViewReader { proxy in
                    List(rows) { process in
                        Button {
                            onPick(process, followByName)
                        } label: {
                            HStack {
                                Text(process.name)
                                Spacer()
                                Text(verbatim: ProcessIdentifierFormatting.identifier(process.id))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .listRowBackground(process.id == highlightedPid ? Color.accentColor.opacity(0.25) : Color.clear)
                        .id(process.id)
                        .accessibilityIdentifier("process-status.picker.row.\(process.id)")
                    }
                    .accessibilityIdentifier("process-status.picker.list")
                    .onChange(of: highlightedPid) { _, pid in
                        if let pid { proxy.scrollTo(pid) }
                    }
                }
            }
            Divider()
            Toggle("Follow by name", isOn: $followByName)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("process-status.picker.follow-by-name")
        }
        .frame(minWidth: 300, minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("process-status.running-process-picker")
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in highlightedPid = nil }
    }

    private func moveHighlight(_ delta: Int, in rows: [ProcessInspector.RunningProcess]) {
        guard !rows.isEmpty else { return }
        let current = highlightedPid.flatMap { pid in rows.firstIndex { $0.id == pid } }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), rows.count - 1)
        } else {
            next = delta > 0 ? 0 : rows.count - 1
        }
        highlightedPid = rows[next].id
    }

    private func pickHighlighted(in rows: [ProcessInspector.RunningProcess]) {
        let chosen = highlightedPid.flatMap { pid in rows.first { $0.id == pid } } ?? rows.first
        guard let chosen else { return }
        onPick(chosen, followByName)
    }

    private func escape() {
        if query.isEmpty {
            onDismiss()
        } else {
            query = ""
        }
    }
}
