import Foundation
import Darwin

/// Live CPU and memory for *this* process, sampled on a timer for the
/// sidebar's status row.
///
/// Both figures are the app's own, not the machine's. Network deliberately
/// isn't here: macOS exposes no public per-process byte counter, and SFTP and
/// SSH run as child processes anyway, so any number shown would either be the
/// whole system's or a guess.
final class ProcessMetrics: ObservableObject {
    static let shared = ProcessMetrics()

    /// Share of one core, as a percentage — the same basis Activity Monitor
    /// uses, so it can exceed 100 on a busy multi-threaded moment.
    @Published private(set) var cpuPercent: Double = 0
    /// Physical footprint in bytes, which is what Activity Monitor reports as
    /// "Memory" — not `resident_size`, which counts pages this process shares
    /// with others and reads high.
    @Published private(set) var memoryBytes: UInt64 = 0

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        // Two seconds is frequent enough to feel live and cheap enough to be
        // invisible in the very number it reports.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Formatting

    var cpuText: String {
        String(format: "%.0f%%", cpuPercent)
    }

    var memoryText: String {
        let megabytes = Double(memoryBytes) / 1_048_576
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return String(format: "%.0f MB", megabytes)
    }

    // MARK: Sampling

    private func sample() {
        let cpu = Self.currentCPUPercent()
        let memory = Self.currentMemoryBytes()
        // Timer fires on the main run loop, so publishing here is already on
        // the main queue.
        if abs(cpu - cpuPercent) > 0.4 { cpuPercent = cpu }
        if memory != memoryBytes { memoryBytes = memory }
    }

    /// Sums per-thread CPU usage. `task_threads` allocates the array it hands
    /// back, so it has to be released with `vm_deallocate` — otherwise this
    /// leaks a little virtual memory on every single sample.
    private static func currentCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return 0 }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        var total: Double = 0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            // THREAD_BASIC_INFO_COUNT is an expression macro, so Swift can't
            // import it — same reason TASK_VM_INFO's count is computed below.
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            // Idle threads still report, so skip them rather than summing noise.
            guard info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
        return total
    }

    private static func currentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
