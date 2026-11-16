import Foundation

/// The names TIFF and Exif give to tags and to their values, which differ by which directory a tag is in.
enum TIFFTags {
    enum Directory: Equatable {
        case image
        case exif
        case gps
        case interoperability
    }

    static func name(_ tag: UInt64, in directory: Directory) -> String? {
        switch directory {
        case .image: return image[tag] ?? exif[tag]
        case .exif: return exif[tag] ?? image[tag]
        case .gps: return gps[tag]
        case .interoperability: return interoperability[tag]
        }
    }

    static let image: [UInt64: String] = [
        0xFE: "NewSubfileType", 0xFF: "SubfileType", 0x100: "ImageWidth", 0x101: "ImageLength", 0x102: "BitsPerSample", 0x103: "Compression",
        0x106: "PhotometricInterpretation", 0x107: "Thresholding", 0x10A: "FillOrder", 0x10D: "DocumentName", 0x10E: "ImageDescription",
        0x10F: "Make", 0x110: "Model", 0x111: "StripOffsets", 0x112: "Orientation", 0x115: "SamplesPerPixel", 0x116: "RowsPerStrip",
        0x117: "StripByteCounts", 0x11A: "XResolution", 0x11B: "YResolution", 0x11C: "PlanarConfiguration", 0x11D: "PageName",
        0x128: "ResolutionUnit", 0x129: "PageNumber", 0x12D: "TransferFunction", 0x131: "Software", 0x132: "DateTime", 0x13B: "Artist",
        0x13C: "HostComputer", 0x13D: "Predictor", 0x13E: "WhitePoint", 0x13F: "PrimaryChromaticities", 0x140: "ColorMap", 0x142: "TileWidth",
        0x143: "TileLength", 0x144: "TileOffsets", 0x145: "TileByteCounts", 0x14A: "SubIFDs", 0x152: "ExtraSamples", 0x153: "SampleFormat",
        0x201: "JPEGInterchangeFormat", 0x202: "JPEGInterchangeFormatLength", 0x211: "YCbCrCoefficients", 0x212: "YCbCrSubSampling",
        0x213: "YCbCrPositioning", 0x214: "ReferenceBlackWhite", 0x2BC: "XMP", 0x8298: "Copyright", 0x83BB: "IPTC-NAA", 0x8649: "PhotoshopImageResources",
        0x8769: "ExifIFDPointer", 0x8773: "ICCProfile", 0x8825: "GPSInfoIFDPointer", 0xC612: "DNGVersion", 0xC614: "UniqueCameraModel"
    ]

    static let exif: [UInt64: String] = [
        0x829A: "ExposureTime", 0x829D: "FNumber", 0x8822: "ExposureProgram", 0x8824: "SpectralSensitivity", 0x8827: "ISOSpeedRatings",
        0x8828: "OECF", 0x8830: "SensitivityType", 0x8832: "RecommendedExposureIndex", 0x9000: "ExifVersion", 0x9003: "DateTimeOriginal",
        0x9004: "DateTimeDigitized", 0x9010: "OffsetTime", 0x9011: "OffsetTimeOriginal", 0x9012: "OffsetTimeDigitized", 0x9101: "ComponentsConfiguration",
        0x9102: "CompressedBitsPerPixel", 0x9201: "ShutterSpeedValue", 0x9202: "ApertureValue", 0x9203: "BrightnessValue", 0x9204: "ExposureBiasValue",
        0x9205: "MaxApertureValue", 0x9206: "SubjectDistance", 0x9207: "MeteringMode", 0x9208: "LightSource", 0x9209: "Flash", 0x920A: "FocalLength",
        0x9214: "SubjectArea", 0x927C: "MakerNote", 0x9286: "UserComment", 0x9290: "SubSecTime", 0x9291: "SubSecTimeOriginal", 0x9292: "SubSecTimeDigitized",
        0xA000: "FlashpixVersion", 0xA001: "ColorSpace", 0xA002: "PixelXDimension", 0xA003: "PixelYDimension", 0xA004: "RelatedSoundFile",
        0xA005: "InteroperabilityIFDPointer", 0xA20B: "FlashEnergy", 0xA20E: "FocalPlaneXResolution", 0xA20F: "FocalPlaneYResolution",
        0xA210: "FocalPlaneResolutionUnit", 0xA214: "SubjectLocation", 0xA215: "ExposureIndex", 0xA217: "SensingMethod", 0xA300: "FileSource",
        0xA301: "SceneType", 0xA302: "CFAPattern", 0xA401: "CustomRendered", 0xA402: "ExposureMode", 0xA403: "WhiteBalance", 0xA404: "DigitalZoomRatio",
        0xA405: "FocalLengthIn35mmFilm", 0xA406: "SceneCaptureType", 0xA407: "GainControl", 0xA408: "Contrast", 0xA409: "Saturation", 0xA40A: "Sharpness",
        0xA40B: "DeviceSettingDescription", 0xA40C: "SubjectDistanceRange", 0xA420: "ImageUniqueID", 0xA430: "CameraOwnerName", 0xA431: "BodySerialNumber",
        0xA432: "LensSpecification", 0xA433: "LensMake", 0xA434: "LensModel", 0xA435: "LensSerialNumber"
    ]

    static let gps: [UInt64: String] = [
        0x00: "GPSVersionID", 0x01: "GPSLatitudeRef", 0x02: "GPSLatitude", 0x03: "GPSLongitudeRef", 0x04: "GPSLongitude", 0x05: "GPSAltitudeRef",
        0x06: "GPSAltitude", 0x07: "GPSTimeStamp", 0x08: "GPSSatellites", 0x09: "GPSStatus", 0x0A: "GPSMeasureMode", 0x0B: "GPSDOP", 0x0C: "GPSSpeedRef",
        0x0D: "GPSSpeed", 0x0E: "GPSTrackRef", 0x0F: "GPSTrack", 0x10: "GPSImgDirectionRef", 0x11: "GPSImgDirection", 0x12: "GPSMapDatum",
        0x13: "GPSDestLatitudeRef", 0x14: "GPSDestLatitude", 0x15: "GPSDestLongitudeRef", 0x16: "GPSDestLongitude", 0x1D: "GPSDateStamp", 0x1E: "GPSDifferential"
    ]

    static let interoperability: [UInt64: String] = [1: "InteroperabilityIndex", 2: "InteroperabilityVersion"]

    /// The tags whose value is where another directory is, and what it holds.
    static func subdirectory(_ tag: UInt64, in directory: Directory) -> (title: String, kind: Directory)? {
        guard directory == .image || directory == .exif else { return nil }
        switch tag {
        case 0x8769: return ("Exif IFD", .exif)
        case 0x8825: return ("GPS IFD", .gps)
        case 0xA005: return ("Interoperability IFD", .interoperability)
        case 0x14A: return ("SubIFD", .image)
        default: return nil
        }
    }

    // MARK: Types

    /// A value type's name and its size in bytes.
    static let types: [UInt64: (name: String, size: Int64)] = [
        1: ("BYTE", 1), 2: ("ASCII", 1), 3: ("SHORT", 2), 4: ("LONG", 4), 5: ("RATIONAL", 8), 6: ("SBYTE", 1), 7: ("UNDEFINED", 1),
        8: ("SSHORT", 2), 9: ("SLONG", 4), 10: ("SRATIONAL", 8), 11: ("FLOAT", 4), 12: ("DOUBLE", 8), 13: ("IFD", 4)
    ]

    // MARK: Values

    /// What a number means for the tags that have a list of meanings.
    static func meaning(of value: UInt64, tag: UInt64, in directory: Directory) -> String? {
        let table: [UInt64: String]
        switch (directory, tag) {
        case (.image, 0x103):
            table = [1: "none", 2: "CCITT 1D", 3: "CCITT Group 3", 4: "CCITT Group 4", 5: "LZW", 6: "JPEG (old style)", 7: "JPEG", 8: "Deflate", 32773: "PackBits",
                     32946: "Deflate (old)", 34712: "JPEG 2000", 50000: "ZSTD", 50001: "WebP"]
        case (.image, 0x106):
            table = [0: "white is zero", 1: "black is zero", 2: "RGB", 3: "palette", 4: "transparency mask", 5: "CMYK", 6: "YCbCr", 8: "CIELab"]
        case (.image, 0x112):
            table = [1: "top left", 2: "top right", 3: "bottom right", 4: "bottom left", 5: "left top", 6: "right top", 7: "right bottom", 8: "left bottom"]
        case (.image, 0x128), (.exif, 0xA210):
            table = [1: "none", 2: "inch", 3: "centimetre"]
        case (.image, 0x11C):
            table = [1: "chunky (RGBRGB…)", 2: "planar (RRR…GGG…BBB…)"]
        case (.image, 0x13D):
            table = [1: "none", 2: "horizontal differencing", 3: "floating point"]
        case (.image, 0x152):
            table = [0: "unspecified", 1: "associated alpha", 2: "unassociated alpha"]
        case (.image, 0x153):
            table = [1: "unsigned integer", 2: "signed integer", 3: "floating point", 4: "undefined"]
        case (.image, 0x213):
            table = [1: "centred", 2: "co-sited"]
        case (.image, 0xFE):
            table = [0: "full-resolution image", 1: "reduced-resolution image", 2: "one page of many", 4: "transparency mask"]
        case (.exif, 0x8822):
            table = [0: "not defined", 1: "manual", 2: "normal", 3: "aperture priority", 4: "shutter priority", 5: "creative", 6: "action", 7: "portrait", 8: "landscape"]
        case (.exif, 0x9207):
            table = [0: "unknown", 1: "average", 2: "centre weighted", 3: "spot", 4: "multi-spot", 5: "pattern", 6: "partial", 255: "other"]
        case (.exif, 0x9209):
            table = [0: "no flash", 1: "fired", 5: "fired, no return light", 7: "fired, return light", 16: "off", 24: "auto, did not fire", 25: "auto, fired"]
        case (.exif, 0xA001):
            table = [1: "sRGB", 65535: "uncalibrated"]
        case (.exif, 0xA402):
            table = [0: "auto", 1: "manual", 2: "auto bracket"]
        case (.exif, 0xA403):
            table = [0: "auto", 1: "manual"]
        case (.exif, 0xA406):
            table = [0: "standard", 1: "landscape", 2: "portrait", 3: "night"]
        case (.gps, 0x09):
            return nil
        default:
            return nil
        }
        return table[value]
    }
}
