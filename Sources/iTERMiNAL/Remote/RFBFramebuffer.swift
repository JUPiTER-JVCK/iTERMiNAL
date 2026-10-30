import Foundation
import CoreGraphics

/// The remote screen as this app holds it: a bitmap of 32-bit pixels, written
/// by the network queue and read by the view, so every access is under a lock.
///
/// Every write is bounds-checked against the bitmap's current size here, again,
/// whatever the caller checked: a rectangle a server made up must not be able to
/// write outside the memory this owns.
final class RFBFramebuffer {
    private let lock = NSLock()
    private var storedWidth: Int
    private var storedHeight: Int
    private var pixels: UnsafeMutableRawPointer

    init?(width: Int, height: Int) {
        guard RFB.isUsableSize(width: width, height: height),
              let memory = calloc(width * height, 4) else { return nil }
        storedWidth = width
        storedHeight = height
        pixels = memory
    }

    deinit {
        free(pixels)
    }

    var size: (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (storedWidth, storedHeight)
    }

    /// A new, blank bitmap of another size, in place: whoever holds this object
    /// keeps a valid one. False, with nothing changed, if the size is not usable
    /// or memory ran out.
    func resize(width: Int, height: Int) -> Bool {
        guard RFB.isUsableSize(width: width, height: height),
              let memory = calloc(width * height, 4) else { return false }
        lock.lock()
        free(pixels)
        pixels = memory
        storedWidth = width
        storedHeight = height
        lock.unlock()
        return true
    }

    /// `rows` is `width × height` pixels, four bytes each, row after row.
    func writeRaw(x: Int, y: Int, width: Int, height: Int, rows: [UInt8]) {
        guard width > 0, height > 0, rows.count == width * height * 4 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard x >= 0, y >= 0, x + width <= storedWidth, y + height <= storedHeight else { return }
        rows.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<height {
                let destination = pixels + ((y + row) * storedWidth + x) * 4
                memcpy(destination, base + row * width * 4, width * 4)
            }
        }
    }

    /// Moves a region of the screen to another place in it, correctly where the
    /// two overlap.
    func copy(fromX sourceX: Int, fromY sourceY: Int, toX x: Int, toY y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard sourceX >= 0, sourceY >= 0, x >= 0, y >= 0,
              sourceX + width <= storedWidth, sourceY + height <= storedHeight,
              x + width <= storedWidth, y + height <= storedHeight else { return }
        var staging = [UInt8](repeating: 0, count: width * height * 4)
        staging.withUnsafeMutableBytes { target in
            guard let base = target.baseAddress else { return }
            for row in 0..<height {
                memcpy(base + row * width * 4, pixels + ((sourceY + row) * storedWidth + sourceX) * 4, width * 4)
            }
        }
        staging.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(pixels + ((y + row) * storedWidth + x) * 4, base + row * width * 4, width * 4)
            }
        }
    }

    /// A picture of the screen as it is now.
    func image() -> CGImage? {
        lock.lock()
        let width = storedWidth
        let height = storedHeight
        let data = Data(bytes: pixels, count: width * height * 4)
        lock.unlock()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
