// FootprintReader.swift

import Darwin
import Foundation

/// Reads the process's own memory footprint via `task_info`.
///
/// **Never RSS.** `ps -o rss` / `task_basic_info.resident_size` excludes
/// compressed and swapped pages — on the field report that motivated this
/// (#0285), RSS under-reported the real footprint by 7-29x because most of
/// the growth had been pushed into the compressor. `phys_footprint` from
/// `TASK_VM_INFO` is the same counter Activity Monitor, `footprint(1)`, and
/// the kernel's own memory-pressure accounting use.
public enum FootprintReader {
    /// The current process's `phys_footprint` in bytes, or `nil` if the
    /// `task_info` call fails (not expected in practice — `mach_task_self_`
    /// always has permission to read its own task info).
    public static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // A kernel that only fills TASK_VM_INFO_REV0_COUNT (documented as
        // predating phys_footprint) would return KERN_SUCCESS with the field
        // left zeroed — treat that the same as a failed read rather than
        // reporting an implausible "0 bytes used" that would silently
        // suppress every future warning. Not reachable on macOS 15.6+, but
        // it's the one path where a failed read masquerades as real data.
        guard result == KERN_SUCCESS, info.phys_footprint > 0 else { return nil }
        return info.phys_footprint
    }
}
