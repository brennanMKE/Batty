// SystemMetricsProcessRowViewTests.swift

import GhosttyTheme
import SwiftUI
import Testing
@testable import BattyKit

/// `.equatable()` skips re-rendering a process row only when this `==`
/// holds, so it must compare exactly the row's values and colors.
@MainActor
struct SystemMetricsProcessRowViewTests {

    private static let row = ProcessRow(pid: 42, name: "kernel_task", path: "/x", cpuPercent: 12, physFootprintBytes: 4_000)

    private static let themed = SystemMetricsColors(palette: ChromePalette(theme: GhosttyThemeDefinition(
        name: "test-dark-green",
        background: "#0b2a1c",
        foreground: "#d6f5e3",
        cursorColor: "#3ddc84",
        palette: [4: "2e8bff", 6: "20c9c9"]
    )))

    @Test func rowViewIsEqualWhenRowAndColorsAreEqual() {
        #expect(
            SystemMetricsProcessRowView(row: Self.row, colors: SystemMetricsColors(palette: nil))
                == SystemMetricsProcessRowView(row: Self.row, colors: SystemMetricsColors(palette: nil))
        )
        #expect(
            SystemMetricsProcessRowView(row: Self.row, colors: Self.themed)
                == SystemMetricsProcessRowView(row: Self.row, colors: Self.themed)
        )
    }

    @Test func rowViewIsUnequalWhenAValueChanges() {
        let base = SystemMetricsProcessRowView(row: Self.row, colors: Self.themed)
        let changedRows = [
            ProcessRow(pid: 42, name: "kernel_task", path: "/x", cpuPercent: 13, physFootprintBytes: 4_000),
            ProcessRow(pid: 42, name: "kernel_task", path: "/x", cpuPercent: 12, physFootprintBytes: 4_001),
            ProcessRow(pid: 42, name: "launchd", path: "/x", cpuPercent: 12, physFootprintBytes: 4_000),
        ]
        for changed in changedRows {
            #expect(base != SystemMetricsProcessRowView(row: changed, colors: Self.themed))
        }
        #expect(base != SystemMetricsProcessRowView(row: Self.row, colors: SystemMetricsColors(palette: nil)))
    }
}
