// SystemMetricsFormatting.swift

import Foundation

/// Pure formatting helpers for the System Metrics view
/// (`docs/design/system-metrics-view.md` §2/§7) — kept separate from the
/// view so they're unit-testable without constructing any SwiftUI type.
/// Byte figures use a binary (1024-based) divisor labeled "GB"/"MB",
/// matching how the design's own mockup renders a 64 GiB machine as
/// "64.00 GB" rather than the decimal-GB convention macOS storage UI uses.
public enum SystemMetricsFormatting {
    public static func bytes(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 {
            return String(format: "%.1f MB", megabytes)
        }
        let gigabytes = megabytes / 1024
        return String(format: "%.2f GB", gigabytes)
    }

    public static func percent(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    public static func celsius(_ value: Double) -> String {
        String(format: "%.1f\u{00B0}C", value)
    }

    public static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded())) RPM"
    }

    public static func loadAverage(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
