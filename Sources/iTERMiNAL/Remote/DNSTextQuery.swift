import Foundation
import dnssd

/// Asks this Mac's resolver for a TXT record. Blocking, with a time limit:
/// call it off the main thread.
///
/// Goes through mDNSResponder (`DNSServiceQueryRecord`) like any other lookup
/// on the Mac, so it follows the system's DNS settings, VPNs and caches.
enum DNSTextQuery {
    private final class Box {
        var text: String?
        var finished = false
    }

    static func txt(_ name: String, timeout: TimeInterval = 5) -> String? {
        let box = Box()
        let context = Unmanaged.passRetained(box)
        defer { context.release() }

        var service: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            if error != DNSServiceErrorType(kDNSServiceErr_NoError) {
                box.finished = true
                return
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data, box.text == nil {
                // TXT data is length-prefixed strings; a record split into
                // several is one value.
                let bytes = UnsafeRawBufferPointer(start: data, count: Int(length))
                var text = ""
                var index = 0
                while index < bytes.count {
                    let size = Int(bytes[index])
                    index += 1
                    guard index + size <= bytes.count else { break }
                    text += String(decoding: bytes[index..<index + size], as: UTF8.self)
                    index += size
                }
                box.text = text
                box.finished = true
            }
        }

        let started = DNSServiceQueryRecord(
            &service,
            0,
            0,
            name,
            UInt16(kDNSServiceType_TXT),
            UInt16(kDNSServiceClass_IN),
            callback,
            context.toOpaque()
        )
        guard started == DNSServiceErrorType(kDNSServiceErr_NoError), let service else { return nil }
        defer { DNSServiceRefDeallocate(service) }

        let descriptor = DNSServiceRefSockFD(service)
        guard descriptor >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while !box.finished {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 60) * 1000))
            if ready < 0 { break }
            if ready > 0 {
                guard DNSServiceProcessResult(service) == DNSServiceErrorType(kDNSServiceErr_NoError) else { break }
            }
        }
        return box.text
    }
}
