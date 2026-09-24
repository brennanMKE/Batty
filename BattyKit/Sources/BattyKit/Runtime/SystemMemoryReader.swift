// SystemMemoryReader.swift

import Darwin
import Foundation

/// System-wide memory breakdown, compressed-aware — the system-level
/// counterpart to `FootprintReader`'s own-process `phys_footprint` rule
/// (`issues/0290.md`'s binding "never RSS" rule, restated at whole-machine
/// scale per `docs/design/system-metrics-view.md` §2). `usedBytes` is
/// active + wired + compressed; compressed is also surfaced on its own
/// because it is exactly the figure that rule exists to keep visible, not
/// fold silently into "used" and hide.
public nonisolated struct MemoryReading: Equatable, Sendable {
    public enum PressureLevel: Int32, Equatable, Sendable {
        case normal = 1
        case warn = 2
        case critical = 4
        case unknown = -1

        public init(rawValue: Int32) {
            switch rawValue {
            case 1: self = .normal
            case 2: self = .warn
            case 4: self = .critical
            default: self = .unknown
            }
        }
    }

    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let pressureLevel: PressureLevel

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        freeBytes: UInt64,
        activeBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        pressureLevel: PressureLevel
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.pressureLevel = pressureLevel
    }

    public static let unavailable = MemoryReading(
        totalBytes: 0, usedBytes: 0, freeBytes: 0, activeBytes: 0,
        wiredBytes: 0, compressedBytes: 0, pressureLevel: .unknown
    )
}

/// Reads `host_statistics64(HOST_VM_INFO64)` + `hw.memsize` +
/// `kern.memorystatus_vm_pressure_level` — all free, sub-millisecond
/// (`docs/design/system-metrics-view.md` §1.6).
///
/// `nonisolated` — see `SystemCPUReader`'s doc comment for why every
/// stateless reader in this file group needs this against BattyKit's
/// package-wide default `MainActor` isolation.
public nonisolated enum SystemMemoryReader {
    public static func current() -> MemoryReading? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let hostPort = mach_host_self()
        // Review round 1 (#0314): mach_host_self() is an owned send right,
        // same as SystemCPUReader.currentTicks()'s own leak fix — released
        // once this function is done with it rather than accumulating one
        // leaked reference per tick.
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(hostPort, &pageSize)
        guard pageSize > 0 else { return nil }
        let pageBytes = UInt64(pageSize)

        var totalBytes: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        // Review round 1 (#0314): this call's return code was unchecked —
        // a failure left `totalBytes` at its initial 0, which would have
        // rendered as a fabricated "of 0.00 GB" denominator (the same
        // zero-as-measurement defect #6 flags elsewhere) rather than the
        // honest "no reading" `nil` this guard now produces.
        guard sysctlbyname("hw.memsize", &totalBytes, &totalSize, nil, 0) == 0 else { return nil }

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        // A failure here leaves `pressureRaw == 0`, which
        // `MemoryReading.PressureLevel.init(rawValue:)` already maps to
        // `.unknown` (no kernel pressure level is defined as 0) — the
        // honest fallback, not a fabricated "Normal."
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0)

        let free = UInt64(stats.free_count) * pageBytes
        let active = UInt64(stats.active_count) * pageBytes
        let wired = UInt64(stats.wire_count) * pageBytes
        let compressed = UInt64(stats.compressor_page_count) * pageBytes

        return MemoryReading(
            totalBytes: totalBytes,
            usedBytes: active + wired + compressed,
            freeBytes: free,
            activeBytes: active,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressureLevel: .init(rawValue: pressureRaw)
        )
    }
}
