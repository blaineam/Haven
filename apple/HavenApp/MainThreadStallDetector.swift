//
//  MainThreadStallDetector.swift
//  Haven
//
//  DEBUG-ONLY. Reports when the main thread stops servicing work AND captures
//  what it was stuck in, so a UI freeze names itself instead of being guessed
//  at. Ported from Ari, where it found five distinct main-thread blocks in
//  minutes after hours of inference failed.
//
//  Why it's here: the "locks up for a few seconds right after foregrounding"
//  report, and the 2 AM background scene-create 0x8BADF00D (main parked >30s
//  behind the engine mutex during an overnight push drain). Short blocks leave
//  nothing in any log; this closes that gap — a background timer probes the
//  main queue, and when a probe goes unanswered past the threshold it suspends
//  the main thread just long enough to walk its frame pointers.
//
//  Safety notes, because this pokes at mach thread state:
//    • Addresses are collected while main is SUSPENDED, and nothing is
//      allocated in that window — `dladdr` (which can malloc) runs only after
//      the thread is resumed. Allocating while main holds the malloc lock
//      would deadlock the very thread we are trying to diagnose.
//    • Every dereference is bounds-checked: the frame chain must stay aligned,
//      non-null, and strictly increasing, otherwise the walk stops.
//    • The whole file is #if DEBUG. None of it ships.
//

import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG

final class MainThreadStallDetector: @unchecked Sendable {
    static let shared = MainThreadStallDetector()

    private let queue = DispatchQueue(label: "com.blaineam.kith.stall-detector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    private var outstandingSince: CFAbsoluteTime?
    private var reportedCurrentStall = false
    /// The main thread's mach port, captured on the main thread at arm time.
    private var mainThread: thread_t = 0
    /// Suspended apps stop servicing the main queue entirely, which is
    /// indistinguishable from a block unless we track lifecycle. Without this,
    /// every backgrounding reports a bogus multi-second "stall".
    private var appIsActive = true

    private init() {}

    private func observeLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.appIsActive = true
            // Discard any probe that was in flight across the suspension.
            self.outstandingSince = nil
            self.reportedCurrentStall = false
            self.lock.unlock()
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.appIsActive = false
            self.outstandingSince = nil
            self.lock.unlock()
        }
        #endif
    }

    func start(threshold: TimeInterval = 0.4) {
        // Must be read ON the main thread — mach_thread_self() is per-thread.
        if Thread.isMainThread {
            mainThread = mach_thread_self()
        } else {
            DispatchQueue.main.sync { self.mainThread = mach_thread_self() }
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }

            self.lock.lock()
            // A suspended app is not a blocked app — skip while inactive.
            guard self.appIsActive else { self.lock.unlock(); return }
            let pending = self.outstandingSince
            let alreadyReported = self.reportedCurrentStall
            self.lock.unlock()

            if let pending {
                let waited = CFAbsoluteTimeGetCurrent() - pending
                if waited > threshold, !alreadyReported {
                    self.lock.lock(); self.reportedCurrentStall = true; self.lock.unlock()
                    HavenLog.sync("[MainStall] blocked \(String(format: "%.2f", waited))s — main thread stack:")
                    for line in self.captureMainStack() { HavenLog.sync("[MainStall]   \(line)") }
                }
                return
            }

            let sentAt = CFAbsoluteTimeGetCurrent()
            self.lock.lock(); self.outstandingSince = sentAt; self.lock.unlock()

            DispatchQueue.main.async {
                let waited = CFAbsoluteTimeGetCurrent() - sentAt
                self.lock.lock()
                let wasReported = self.reportedCurrentStall
                self.outstandingSince = nil
                self.reportedCurrentStall = false
                self.lock.unlock()
                if waited > threshold {
                    HavenLog.sync("[MainStall] \(wasReported ? "recovered after" : "stalled") \(String(format: "%.2f", waited))s")
                }
            }
        }
        observeLifecycle()
        t.resume()
        timer = t
        HavenLog.sync("[MainStall] detector armed (threshold \(threshold)s, stack capture on)")
    }

    // MARK: - Stack capture

    /// Raw return addresses of the main thread, symbolicated after resume.
    private func captureMainStack(maxFrames: Int = 32) -> [String] {
        #if !arch(arm64)
        // The frame-pointer walk below is written against ARM_THREAD_STATE64;
        // on x86_64 report rather than read the wrong thread-state layout.
        return ["<main-thread stack capture is arm64-only>"]
        #else
        guard mainThread != 0 else { return ["<no main thread port>"] }

        var addresses: [UInt] = []
        addresses.reserveCapacity(maxFrames)

        // ---- suspended window: no allocation past the reserve above ----
        guard thread_suspend(mainThread) == KERN_SUCCESS else {
            return ["<could not suspend main thread>"]
        }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) { statePtr in
            statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(mainThread, ARM_THREAD_STATE64, raw, &count)
            }
        }

        if kr == KERN_SUCCESS {
            addresses.append(UInt(state.__pc))
            addresses.append(UInt(state.__lr))

            // Frame chain: [fp] = caller fp, [fp + 8] = caller lr.
            var fp = UInt(state.__fp)
            var previousFP: UInt = 0
            while addresses.count < maxFrames,
                  fp != 0,
                  fp % 8 == 0,
                  fp > previousFP,
                  let framePtr = UnsafePointer<UInt>(bitPattern: fp) {
                let callerFP = framePtr.pointee
                let callerLR = framePtr.advanced(by: 1).pointee
                if callerLR == 0 { break }
                addresses.append(callerLR)
                previousFP = fp
                fp = callerFP
            }
        }

        thread_resume(mainThread)
        // ---- end suspended window; allocation is safe again ----

        guard !addresses.isEmpty else { return ["<thread_get_state failed: \(kr)>"] }

        return addresses.enumerated().map { index, address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                  let namePtr = info.dli_sname else {
                return String(format: "%2d  0x%016lx  <unknown>", index, address)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let symbol = String(cString: namePtr)
            let offset = address &- UInt(bitPattern: info.dli_saddr)
            return "\(index)  \(image)  \(symbol) + \(offset)"
        }
        #endif
    }
}

#endif
