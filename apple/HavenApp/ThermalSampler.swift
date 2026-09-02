//
//  ThermalSampler.swift
//  Haven
//
//  DEBUG-ONLY. Owner's report, 2026-09-01: the Debug build runs warm on his
//  iPhone (ProcessInfo thermal state .fair, not .nominal). Measure before
//  guessing: every 30s append one line to Library/Caches/HavenThermal.log —
//  ISO timestamp, thermal state, this process's CPU% since the last sample
//  (task user+system time deltas over wall time; >100% means more than one
//  core), and the top 3 threads by CPU in that window with their names (GCD
//  names a worker after the queue it is serving). Thermal-state changes are
//  logged the moment the system posts them. Pull the file the same way as
//  HavenStalls.log:
//    xcrun devicectl device copy from --domain-type appDataContainer
//      --domain-identifier com.blaineam.kith
//      --source Library/Caches/HavenThermal.log --destination /tmp/thermal.log
//
//  Cost: one task_info + one task_threads walk per sample on a utility queue
//  — microseconds, nothing on the main thread. The whole file is #if DEBUG.
//

import Foundation
import Darwin

#if DEBUG

final class ThermalSampler: @unchecked Sendable {
    static let shared = ThermalSampler()

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("HavenThermal.log")
    }()

    private let queue = DispatchQueue(label: "haven.thermal.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastWall: CFAbsoluteTime = 0
    private var lastCPU: Double = 0                       // process user+system seconds
    private var lastThreadCPU: [UInt64: Double] = [:]     // thread id → user+system seconds
    private var observer: NSObjectProtocol?

    func start(interval: TimeInterval = 30) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.sample(reason: "sample") }
        t.resume()
        timer = t
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.sample(reason: "thermal-state CHANGED") }
        }
        emit("[Thermal] sampler armed (every \(Int(interval))s) state=\(Self.name(ProcessInfo.processInfo.thermalState))")
    }

    // MARK: - Sampling

    private func sample(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let cpu = Self.processCPUSeconds()
        let threads = Self.threadCPUSeconds()
        var line = "[Thermal] \(reason) state=\(Self.name(ProcessInfo.processInfo.thermalState))"
        if lastWall > 0 {
            let wall = max(0.001, now - lastWall)
            let pct = (cpu - lastCPU) / wall * 100
            line += String(format: " cpu=%.1f%% (%.1fs window)", pct, wall)
            // Top 3 threads by CPU consumed in this window.
            var deltas: [(name: String, pct: Double)] = []
            for (tid, t) in threads {
                let d = t.seconds - (lastThreadCPU[tid] ?? 0)
                if d > 0.005 { deltas.append((t.name, d / wall * 100)) }
            }
            let top = deltas.sorted { $0.pct > $1.pct }.prefix(3)
                .map { String(format: "%@ %.1f%%", $0.name, $0.pct) }
            if !top.isEmpty { line += " top: " + top.joined(separator: " | ") }
        } else {
            line += String(format: " cpu-total=%.1fs (first sample, no window yet)", cpu)
        }
        lastWall = now
        lastCPU = cpu
        lastThreadCPU = threads.mapValues { $0.seconds }
        emit(line)
    }

    /// user+system CPU seconds for the whole task: live threads (TASK_THREAD_TIMES_INFO) plus
    /// threads that already exited (TASK_BASIC_INFO accumulates those).
    private static func processCPUSeconds() -> Double {
        var live = task_thread_times_info_data_t()
        var liveCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let liveOK = withUnsafeMutablePointer(to: &live) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        } == KERN_SUCCESS
        var basic = task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let basicOK = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        } == KERN_SUCCESS
        var total = 0.0
        if liveOK { total += seconds(live.user_time) + seconds(live.system_time) }
        if basicOK { total += seconds(basic.user_time) + seconds(basic.system_time) }
        return total
    }

    /// Per-thread user+system CPU seconds keyed by kernel thread id, with the thread's name.
    private static func threadCPUSeconds() -> [UInt64: (name: String, seconds: Double)] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            let bytes = vm_size_t(Int(count) * MemoryLayout<thread_act_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), bytes)
        }
        var out: [UInt64: (name: String, seconds: Double)] = [:]
        for i in 0..<Int(count) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var basic = thread_basic_info_data_t()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let basicOK = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            } == KERN_SUCCESS
            guard basicOK, basic.flags & TH_FLAGS_IDLE == 0 else { continue }
            var ident = thread_identifier_info_data_t()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identOK = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            } == KERN_SUCCESS
            guard identOK else { continue }
            var ext = thread_extended_info_data_t()
            var extCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let extOK = withUnsafeMutablePointer(to: &ext) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extCount)
                }
            } == KERN_SUCCESS
            var name = ""
            if extOK {
                name = withUnsafePointer(to: &ext.pth_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXTHREADNAMESIZE)) { String(cString: $0) }
                }
            }
            if name.isEmpty { name = i == 0 ? "main" : "thread#\(ident.thread_id)" }
            out[ident.thread_id] = (name, seconds(basic.user_time) + seconds(basic.system_time))
        }
        return out
    }

    private static func seconds(_ t: time_value_t) -> Double {
        Double(t.seconds) + Double(t.microseconds) / 1_000_000
    }

    private static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Sink (same shape as the stall detector's)

    private func emit(_ line: String) {
        HavenLog.sync(line)
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.fileURL)
        }
    }
}

#endif
