import Foundation

/// Says what a file is from its first bytes, for the formats there is no structure
/// view for yet and for the Structure outlook's header. A signature is a guess, and is
/// worded as one: "looks like".
enum FormatDetector {
    private struct Signature {
        let id: String
        let name: String
        let detail: String
        let offset: Int
        let bytes: [UInt8]
    }

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static let signatures: [Signature] = [
        Signature(id: "png", name: "a PNG image", detail: "Portable Network Graphics", offset: 0,
                  bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        Signature(id: "jpeg", name: "a JPEG image", detail: "JPEG, from its start-of-image marker", offset: 0, bytes: [0xFF, 0xD8, 0xFF]),
        Signature(id: "gif", name: "a GIF image", detail: "Graphics Interchange Format", offset: 0, bytes: ascii("GIF8")),
        Signature(id: "tiff", name: "a TIFF image", detail: "Tagged Image File Format, little-endian", offset: 0, bytes: [0x49, 0x49, 0x2A, 0x00]),
        Signature(id: "tiff", name: "a TIFF image", detail: "Tagged Image File Format, big-endian", offset: 0, bytes: [0x4D, 0x4D, 0x00, 0x2A]),
        Signature(id: "pdf", name: "a PDF document", detail: "Portable Document Format", offset: 0, bytes: ascii("%PDF-")),
        Signature(id: "zip", name: "a ZIP archive", detail: "also the container of .docx, .xlsx, .jar and .apk files", offset: 0, bytes: [0x50, 0x4B, 0x03, 0x04]),
        Signature(id: "zip", name: "an empty ZIP archive", detail: "just the end-of-archive record", offset: 0, bytes: [0x50, 0x4B, 0x05, 0x06]),
        Signature(id: "gzip", name: "gzip-compressed data", detail: "RFC 1952", offset: 0, bytes: [0x1F, 0x8B, 0x08]),
        Signature(id: "bzip2", name: "bzip2-compressed data", detail: "BZh and a block size", offset: 0, bytes: ascii("BZh")),
        Signature(id: "xz", name: "xz-compressed data", detail: "LZMA2 container", offset: 0, bytes: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
        Signature(id: "zstd", name: "Zstandard-compressed data", detail: "zstd frame", offset: 0, bytes: [0x28, 0xB5, 0x2F, 0xFD]),
        Signature(id: "lz4", name: "LZ4-compressed data", detail: "LZ4 frame", offset: 0, bytes: [0x04, 0x22, 0x4D, 0x18]),
        Signature(id: "7z", name: "a 7-Zip archive", detail: "7z", offset: 0, bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),
        Signature(id: "rar", name: "a RAR archive", detail: "Roshal Archive", offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]),
        Signature(id: "tar", name: "a tar archive", detail: "POSIX ustar header", offset: 257, bytes: ascii("ustar")),
        Signature(id: "ar", name: "an ar archive", detail: "also .deb packages and static libraries", offset: 0, bytes: ascii("!<arch>\n")),
        Signature(id: "elf", name: "an ELF program or library", detail: "Executable and Linkable Format", offset: 0, bytes: [0x7F, 0x45, 0x4C, 0x46]),
        Signature(id: "macho", name: "a Mach-O program or library", detail: "32-bit, big-endian", offset: 0, bytes: [0xFE, 0xED, 0xFA, 0xCE]),
        Signature(id: "macho", name: "a Mach-O program or library", detail: "64-bit, big-endian", offset: 0, bytes: [0xFE, 0xED, 0xFA, 0xCF]),
        Signature(id: "macho", name: "a Mach-O program or library", detail: "32-bit, little-endian", offset: 0, bytes: [0xCE, 0xFA, 0xED, 0xFE]),
        Signature(id: "macho", name: "a Mach-O program or library", detail: "64-bit, little-endian", offset: 0, bytes: [0xCF, 0xFA, 0xED, 0xFE]),
        Signature(id: "sqlite", name: "an SQLite database", detail: "database file format 3", offset: 0, bytes: ascii("SQLite format 3\0")),
        Signature(id: "matroska", name: "a Matroska or WebM video", detail: "EBML header", offset: 0, bytes: [0x1A, 0x45, 0xDF, 0xA3]),
        Signature(id: "mp3", name: "an MP3 audio file", detail: "with an ID3 tag", offset: 0, bytes: ascii("ID3")),
        Signature(id: "ogg", name: "an Ogg file", detail: "Vorbis, Opus or Theora", offset: 0, bytes: ascii("OggS")),
        Signature(id: "flac", name: "a FLAC audio file", detail: "Free Lossless Audio Codec", offset: 0, bytes: ascii("fLaC")),
        Signature(id: "midi", name: "a MIDI file", detail: "Standard MIDI", offset: 0, bytes: ascii("MThd")),
        Signature(id: "wasm", name: "a WebAssembly module", detail: "binary format", offset: 0, bytes: [0x00, 0x61, 0x73, 0x6D]),
        Signature(id: "pcap", name: "a packet capture (pcap)", detail: "little-endian, microseconds", offset: 0, bytes: [0xD4, 0xC3, 0xB2, 0xA1]),
        Signature(id: "pcap", name: "a packet capture (pcap)", detail: "big-endian, microseconds", offset: 0, bytes: [0xA1, 0xB2, 0xC3, 0xD4]),
        Signature(id: "pcap", name: "a packet capture (pcap)", detail: "little-endian, nanoseconds", offset: 0, bytes: [0x4D, 0x3C, 0xB2, 0xA1]),
        Signature(id: "pcap", name: "a packet capture (pcap)", detail: "big-endian, nanoseconds", offset: 0, bytes: [0xA1, 0xB2, 0x3C, 0x4D]),
        Signature(id: "pcapng", name: "a packet capture (pcapng)", detail: "section header block", offset: 0, bytes: [0x0A, 0x0D, 0x0D, 0x0A]),
        Signature(id: "script", name: "a script", detail: "starts with #!", offset: 0, bytes: ascii("#!")),
        Signature(id: "xml", name: "an XML document", detail: "starts with <?xml", offset: 0, bytes: ascii("<?xml")),
        Signature(id: "rtf", name: "an RTF document", detail: "Rich Text Format", offset: 0, bytes: ascii("{\\rtf")),
        Signature(id: "ps", name: "a PostScript file", detail: "starts with %!PS", offset: 0, bytes: ascii("%!PS")),
        Signature(id: "woff", name: "a WOFF font", detail: "Web Open Font Format", offset: 0, bytes: ascii("wOFF")),
        Signature(id: "woff2", name: "a WOFF2 font", detail: "Web Open Font Format 2", offset: 0, bytes: ascii("wOF2")),
        Signature(id: "otf", name: "an OpenType font", detail: "CFF outlines", offset: 0, bytes: ascii("OTTO")),
    ]

    /// What `head` — the first bytes of a file `length` bytes long — looks like, or nil.
    static func identify(head: [UInt8], length: Int64) -> FormatIdentity? {
        guard !head.isEmpty else { return nil }
        let parsed = FormatRegistry.parserIDs

        func identity(_ id: String, _ name: String, _ detail: String) -> FormatIdentity {
            FormatIdentity(id: id, name: name, detail: detail, hasParser: parsed.contains(id))
        }
        func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<(offset + bytes.count)]) == bytes
        }

        // Where one signature serves two formats, or is too short to trust alone.
        if starts(with: [0xCA, 0xFE, 0xBA, 0xBE]), head.count >= 8 {
            let major = Int(head[6]) << 8 | Int(head[7])
            return major >= 45
                ? identity("class", "a Java class file", "version \(major)")
                : identity("macho", "a Mach-O program or library", "universal binary, \(Int(head[7])) architectures")
        }
        if starts(with: ascii("RIFF")), head.count >= 12 {
            switch String(decoding: head[8..<12], as: UTF8.self) {
            case "WAVE": return identity("wav", "a WAV audio file", "RIFF waveform")
            case "AVI ": return identity("avi", "an AVI video", "RIFF audio video interleave")
            case "WEBP": return identity("webp", "a WebP image", "RIFF container")
            default: return identity("riff", "a RIFF file", "chunked container")
            }
        }
        if head.count >= 12, starts(with: ascii("ftyp"), at: 4) {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            return identity("mp4", "an MP4 or QuickTime video", "ISO base media, brand \"\(brand)\"")
        }
        if head.count >= 8, ["moov", "mdat", "wide", "free", "skip"].contains(String(decoding: head[4..<8], as: UTF8.self)) {
            return identity("mp4", "a QuickTime movie", "begins with a \(String(decoding: head[4..<8], as: UTF8.self)) atom")
        }
        if starts(with: ascii("BM")), head.count >= 14, head[6..<10].allSatisfy({ $0 == 0 }) {
            return identity("bmp", "a BMP image", "Windows bitmap")
        }
        if starts(with: [0x00, 0x00, 0x01, 0x00]), head.count >= 6, head[4] >= 1, head[5] == 0 {
            return identity("ico", "a Windows icon", "\(head[4]) images")
        }
        if starts(with: ascii("MZ")), head.count >= 64 {
            let peOffset = Int(head[60]) | Int(head[61]) << 8 | Int(head[62]) << 16 | Int(head[63]) << 24
            if peOffset + 4 <= head.count {
                if Array(head[peOffset..<(peOffset + 4)]) == [0x50, 0x45, 0x00, 0x00] {
                    return identity("pe", "a Windows program (PE)", "Portable Executable")
                }
            } else if peOffset < Int(length) {
                return identity("pe", "a Windows program (PE)", "Portable Executable")
            }
            return identity("dos", "a DOS program", "MZ executable")
        }
        let lowered = String(decoding: head.prefix(16), as: UTF8.self).lowercased()
        if lowered.hasPrefix("<!doctype html") || lowered.hasPrefix("<html") {
            return identity("html", "an HTML document", "starts with an HTML tag")
        }

        for signature in signatures where starts(with: signature.bytes, at: signature.offset) {
            return identity(signature.id, signature.name, signature.detail)
        }

        return textGuess(head)
    }

    /// Text if what there is of it reads as text: no NULs, and almost nothing but
    /// printable characters, tabs and line ends.
    private static func textGuess(_ head: [UInt8]) -> FormatIdentity? {
        let sample = head.prefix(2048)
        guard !sample.isEmpty, !sample.contains(0) else { return nil }
        let allowedControls: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D]
        let odd = sample.filter { ($0 < 0x20 && !allowedControls.contains($0)) || $0 == 0x7F }.count
        guard odd * 50 <= sample.count else { return nil }
        return FormatIdentity(id: "text", name: "text", detail: isUTF8(Array(sample)) ? "valid UTF-8" : "not valid UTF-8", hasParser: false)
    }

    /// Whether `bytes` is valid UTF-8, allowing the last character to have been cut
    /// in two by where the sample ended.
    private static func isUTF8(_ bytes: [UInt8]) -> Bool {
        for cut in 0...3 where bytes.count > cut {
            let part = Array(bytes.dropLast(cut))
            if Array(String(decoding: part, as: UTF8.self).utf8) == part { return true }
        }
        return false
    }
}
