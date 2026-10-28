import Darwin
import Foundation
import IOKit

/// CPU and GPU load, sampled between calls: the whole Mac's CPU, MotionForge's own share of it, and
/// how busy the GPU is (IOKit's "Device Utilization %", the figure Activity Monitor's GPU history shows).
struct SystemLoadSampler {
    struct Sample {
        var cpu: Double?   // 0–100, all cores
        var app: Double?   // 0–100, this process, as a share of all cores
        var gpu: Double?   // 0–100
    }

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcess: (cpu: Double, wall: Double)?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    mutating func sample() -> Sample {
        var s = Sample()
        if let t = Self.cpuTicks() {
            if let l = lastTicks, t.total > l.total { s.cpu = 100 * Double(t.busy - l.busy) / Double(t.total - l.total) }
            lastTicks = t
        }
        let now = (cpu: Self.processCPUSeconds(), wall: Date().timeIntervalSince1970)
        if let l = lastProcess, now.wall > l.wall { s.app = min(100, 100 * (now.cpu - l.cpu) / (now.wall - l.wall) / cores) }
        lastProcess = now
        s.gpu = Self.gpuUtilization()
        return s
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let u = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, u.doubleValue)
            }
        }
        return best
    }
}
