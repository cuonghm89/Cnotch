//
//  SystemStatsManager.swift
//  CNotch
//
//  CPU and memory usage via the standard Mach host_statistics APIs --
//  no special permission required.
//

import Darwin
import Foundation

final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: Double = 0

    private var timer: Timer?
    private var previousCPUTicks: host_cpu_load_info?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        previousCPUTicks = nil
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        previousCPUTicks = nil
    }

    private func refresh() {
        let cpu = readCPUUsage()
        let memory = readMemoryUsage()
        DispatchQueue.main.async {
            if let cpu { self.cpuUsage = cpu }
            if let memory { self.memoryUsage = memory }
        }
    }

    private func readCPUUsage() -> Double? {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousCPUTicks = cpuInfo }
        guard let previous = previousCPUTicks else { return nil }

        let user = Double(cpuInfo.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total
    }

    private func readMemoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(vm_kernel_page_size)
        let used = Double(stats.active_count + stats.inactive_count + stats.wire_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(1, used / total)
    }
}
