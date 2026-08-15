import Foundation
import os
import SwiftUI

/// What the app is actually holding, and how much headroom iOS will still give it.
///
/// A memory kill leaves no crash report in the app's own logs — the process is simply gone — so
/// "it crashed" and "it was killed for memory" look identical from the outside, and the only
/// diagnostics are a jetsam report that may name a different process entirely. A trace that ends at
/// 1.4 GB with 30 MB of headroom left is not ambiguous; a guess about which screen allocated too
/// much is.
///
/// `phys_footprint` is the number iOS actually judges — the same one Xcode's memory gauge shows —
/// not resident size, which counts pages the kernel is free to evict and so understates a bitmap
/// cache. `os_proc_available_memory` is what remains of this process's limit, which is the half that
/// says whether a climb is survivable.
enum MemoryProbe {

    /// Megabytes of physical footprint, or nil if the kernel declines to answer.
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Megabytes this process may still allocate before iOS kills it — nil where the question does
    /// not apply.
    ///
    /// `os_proc_available_memory` is iOS-family only; on macOS it does not exist at all, and the
    /// concept barely does — a Mac app has no fixed per-process allotment to count down from. This
    /// compiled fine locally for iOS and took out the macOS archive in Xcode Cloud, which is the
    /// whole reason the platform gate is spelled out rather than assumed.
    static func availableMB() -> Double? {
        #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return nil
        #endif
    }

    /// One line: `note — 512 MB used, 900 MB headroom`.
    static func line(_ note: String) -> String {
        let used = footprintMB().map { String(format: "%.0f MB used", $0) } ?? "footprint unknown"
        guard let headroom = availableMB() else { return "\(note) — \(used)" }
        return String(format: "%@ — %@, %.0f MB headroom", note, used, headroom)
    }
}

extension View {
    /// Sample memory every half second for as long as this view is on screen, DEBUG only.
    ///
    /// Attached to a screen suspected of being killed for memory. It costs a `task_info` call per
    /// tick, it never ships (HavenLog only echoes to stdout in DEBUG anyway, which is the only way
    /// to read it from a network-paired phone), and the trace it leaves is the difference between
    /// knowing a screen ran out of memory and believing it did.
    @ViewBuilder func memoryTrace(_ label: @escaping () -> String) -> some View {
        #if DEBUG
        self.task {
            while !Task.isCancelled {
                HavenLog.sync(MemoryProbe.line(label()))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        #else
        self
        #endif
    }
}
