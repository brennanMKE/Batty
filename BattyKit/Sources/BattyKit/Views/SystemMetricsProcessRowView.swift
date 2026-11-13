// SystemMetricsProcessRowView.swift

import AppKit
import SwiftUI

/// One row of System Metrics' process list. `Equatable` over exactly the
/// two stored values, so `.equatable()` skips rows whose values didn't
/// change on a tick; keep closures and environment reads out of it.
struct SystemMetricsProcessRowView: View, Equatable {
    static let pidColumnWidth: CGFloat = 48
    static let cpuColumnWidth: CGFloat = 44
    static let memoryColumnWidth: CGFloat = 62
    static let columnSpacing: CGFloat = 6

    let row: ProcessRow
    let colors: SystemMetricsColors

    var body: some View {
        let denied = row.cpuPercent == nil && row.physFootprintBytes == nil
        HStack(spacing: Self.columnSpacing) {
            Text(row.name)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: String(row.pid))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(colors.mutedForeground.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                .frame(width: Self.pidColumnWidth, alignment: .trailing)
            Text(row.cpuPercent.map { SystemMetricsFormatting.percent($0) } ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            Text(row.physFootprintBytes.map(SystemMetricsFormatting.bytes) ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(denied ? mutedRowStyle : primaryRowStyle)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colors.separator ?? Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
    }

    private var primaryRowStyle: AnyShapeStyle {
        colors.foreground.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)
    }

    private var mutedRowStyle: AnyShapeStyle {
        colors.mutedForeground.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary)
    }

    @ViewBuilder
    private var contextMenu: some View {
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
