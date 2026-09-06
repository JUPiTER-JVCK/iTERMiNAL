import Foundation
import Darwin
import IOKit

/// Live CPU, memory, GPU and network for *the machine*, sampled on a timer for
/// the sidebar's status row.
///
/// The sibling of `ProcessMetrics`, which reports this app's own footprint.
/// Keeping them apart is deliberate: the two answer different questions, and
/// showing both under one "CPU" label would be a lie. The app's own figures
/// still appear, in this row's tooltip.
///
/// Note the different basis for CPU. `ProcessMetrics` reports a share of one
/// core, so it can exceed 100. This reports a share of the whole machine, so it
/// cannot.
///
/// Everything here is public API and needs no privilege: the app is built with
/// `ENABLE_APP_SANDBOX: NO` (see project.yml), so the Mach host calls and the
/// IOKit registry read below are all reachable.
final class SystemMetrics: ObservableObject {
    static let shared = SystemMetrics()

    /// Busy share of the whole machine, 0-100.
    @Published private(set) var cpuPercent: Double = 0
    /// Used share of physical memory, 0-100.
    @Published private(set) var memoryPercent: Double = 0
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = 0
    /// nil when the machine exposes no readable accelerator, so the view can
    /// drop the readout rather than show a confident and wrong `0%`.
    @Published private(set) var gpuPercent: Double?
    @Published private(set) var gpuName: String?
    @Published private(set) var networkInBytesPerSecond: Double = 0
    @Published private(set) var networkOutBytesPerSecond: Double = 0

    private var timer: Timer?

    /// Sampling runs off the main thread: the IOKit registry read is the one
    /// call here expensive enough to be felt as input lag in a terminal. The
    /// queue is serial, so samples cannot overlap and the delta state below is
    /// only ever touched from one thread.
    private let queue = DispatchQueue(label: "com.jupiterjvck.iterminal.systemmetrics", qos: .utility)

    /// Acquired once. `mach_host_self()` hands back a send right on every call,
    /// so calling it per sample leaks port references — the same class of leak
    /// `ProcessMetrics` avoids with its `vm_deallocate`.
    private let host = mach_host_self()

    // Delta state. Queue-confined.
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousNetwork: (input: UInt64, output: UInt64)?
    private var previousTimestamp: DispatchTime?
    private var hasPrimedGPU = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        // No priming read here on purpose. The first sample() primes and
        // reports no GPU figure; the one after it measures a full interval.
        // Priming here instead would leave that first sample reading a window
        // microseconds wide, which is noise.
        sample()
        // Matches ProcessMetrics: frequent enough to feel live, cheap enough to
        // stay invisible in the numbers it reports.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { [weak self] in
            // Deltas measured across a stopped stretch would span an arbitrary
            // gap, so drop them and let the next start() re-baseline.
            self?.previousTicks = nil
            self?.previousNetwork = nil
            self?.previousTimestamp = nil
            self?.hasPrimedGPU = false
        }
    }

    // MARK: Formatting

    var cpuText: String { String(format: "%.0f%%", cpuPercent) }

    var memoryText: String { String(format: "%.0f%%", memoryPercent) }

    var gpuText: String? {
        guard let gpuPercent else { return nil }
        return String(format: "%.0f%%", gpuPercent)
    }

    /// Combined throughput, for the one cell the row has room for. The
    /// direction split lives in the tooltip.
    var networkText: String {
        Self.rateText(networkInBytesPerSecond + networkOutBytesPerSecond)
    }

    /// The detail that does not fit in four cells, as a tooltip body.
    var detailText: String {
        var lines = [
            "CPU  \(cpuText) of all cores",
            "RAM  \(Self.byteText(memoryUsedBytes)) of \(Self.byteText(memoryTotalBytes)) used",
        ]
        if let gpuText {
            lines.append("GPU  \(gpuText)\(gpuName.map { " — \($0)" } ?? "")")
        }
        lines.append("NET  down \(Self.rateText(networkInBytesPerSecond)) · up \(Self.rateText(networkOutBytesPerSecond))")
        return lines.joined(separator: "\n")
    }

    static func rateText(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }

    static func byteText(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Sampling

    private func sample() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            // Elapsed time is measured, never assumed to be the timer's 2.0s:
            // timers are coalesced when the app is in the background, and
            // dividing a real byte delta by a nominal interval overstates the
            // rate.
            let elapsed = self.previousTimestamp.map {
                Double(now.uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000_000
            }
            self.previousTimestamp = now

            let cpu = self.sampleCPU()
            let memory = self.sampleMemory()
            let gpu = self.sampleGPU()
            let network = self.sampleNetwork(elapsed: elapsed)

            DispatchQueue.main.async {
                self.publish(cpu: cpu, memory: memory, gpu: gpu, network: network)
            }
        }
    }

    private func publish(
        cpu: Double?,
        memory: (used: UInt64, total: UInt64)?,
        gpu: (percent: Double, name: String?)?,
        network: (input: Double, output: Double)?
    ) {
        // Publish only on a change big enough to redraw for, so the sidebar
        // isn't invalidated four times every two seconds.
        if let cpu, abs(cpu - cpuPercent) > 0.5 { cpuPercent = cpu }

        if let memory, memory.total > 0 {
            let percent = Double(memory.used) / Double(memory.total) * 100
            if abs(percent - memoryPercent) > 0.5 { memoryPercent = percent }
            if memory.used != memoryUsedBytes { memoryUsedBytes = memory.used }
            if memory.total != memoryTotalBytes { memoryTotalBytes = memory.total }
        }

        if let gpu {
            if gpuPercent == nil || abs(gpu.percent - (gpuPercent ?? 0)) > 0.5 { gpuPercent = gpu.percent }
            if gpu.name != gpuName { gpuName = gpu.name }
        } else if gpuPercent != nil {
            gpuPercent = nil
            gpuName = nil
        }

        if let network {
            // A rate genuinely moves, so the threshold is relative — but with a
            // floor, or an idle link would republish on every stray packet.
            if abs(network.input - networkInBytesPerSecond) > max(256, networkInBytesPerSecond * 0.02) {
                networkInBytesPerSecond = network.input
            }
            if abs(network.output - networkOutBytesPerSecond) > max(256, networkOutBytesPerSecond * 0.02) {
                networkOutBytesPerSecond = network.output
            }
        }
    }

    /// System-wide busy share, from the difference between two readings of the
    /// kernel's cumulative tick counters.
    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = (
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }

        // Tick counters can appear to move backwards across sleep/wake. Clamped
        // rather than subtracted unsigned, which would wrap to something huge.
        let user = Self.delta(ticks.user, previous.user)
        let system = Self.delta(ticks.system, previous.system)
        let idle = Self.delta(ticks.idle, previous.idle)
        let nice = Self.delta(ticks.nice, previous.nice)

        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    /// Approximates Activity Monitor's "Memory Used": the pages that are
    /// resident and cannot simply be dropped. Not an exact match for its
    /// figure, which folds in accounting this call doesn't expose.
    private func sampleMemory() -> (used: UInt64, total: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // vm_kernel_page_size, not a hardcoded 4096: Apple Silicon pages are 16K
        // and these counts are expressed in kernel pages.
        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * pageSize

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return nil }
        return (used: used, total: total)
    }

    /// Reads the accelerator's utilisation counter without taking a
    /// measurement, to close whatever interval another process left open. See
    /// sampleGPU() for why that matters.
    private func primeGPU() {
        _ = readGPU()
        hasPrimedGPU = true
    }

    /// `Device Utilization %` is an average over the interval since the counter
    /// was last read *by any process on the machine* — so a first reading
    /// inherits a stranger's window and famously reports ~98% on an idle Mac.
    /// Priming closes that window; from then on every interval is bounded by two
    /// of our own reads.
    private func sampleGPU() -> (percent: Double, name: String?)? {
        if !hasPrimedGPU {
            primeGPU()
            return nil
        }
        return readGPU()
    }

    private func readGPU() -> (percent: Double, name: String?)? {
        var iterator: io_iterator_t = 0
        // Passed straight through rather than bound to a local first:
        // IOServiceMatching hands back a CFMutableDictionary and this parameter
        // wants a CFDictionary, which Swift will not bridge across a let.
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        // The key differs by GPU family and none of them is documented.
        let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]

        // Intel Macs can carry two accelerators; the busier one is where the
        // work actually is.
        var best: (percent: Double, name: String?)?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            var reading: Double?
            for key in keys {
                if let number = statistics[key] as? NSNumber {
                    reading = number.doubleValue
                    break
                }
            }
            guard let reading else { continue }

            let percent = min(100, max(0, reading))
            if best == nil || percent > best!.percent {
                let name = IORegistryEntryCreateCFProperty(
                    service, "IOClass" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String
                best = (percent: percent, name: name)
            }
        }
        return best
    }

    /// Link-layer byte counters summed across every interface but loopback —
    /// local traffic would otherwise show up as network throughput.
    private func sampleNetwork(elapsed: Double?) -> (input: Double, output: Double)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var pointer = addresses
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: current.pointee.ifa_name) != "lo0",
                  let raw = current.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self)
            // Widened before summing: each interface's counter is 32-bit,
            // but several of them added together need not fit in one.
            input += UInt64(data.pointee.ifi_ibytes)
            output += UInt64(data.pointee.ifi_obytes)
        }

        let totals = (input: input, output: output)
        defer { previousNetwork = totals }
        guard let previous = previousNetwork, let elapsed, elapsed > 0 else { return nil }

        // The underlying counters are 32-bit and reset when an interface
        // drops (Wi-Fi reconnect, VPN up/down), and one wrapping shows up here
        // as the total stepping backwards. That means "no reading", not a spike.
        return (
            input: Double(Self.delta(totals.input, previous.input)) / elapsed,
            output: Double(Self.delta(totals.output, previous.output)) / elapsed
        )
    }

    /// Difference between two readings of a cumulative counter, clamped at
    /// zero: a backwards step means the counter reset or wrapped, and unsigned
    /// subtraction would turn that into a spectacular fake spike.
    private static func delta<T: FixedWidthInteger>(_ current: T, _ previous: T) -> T {
        current >= previous ? current - previous : 0
    }
}
