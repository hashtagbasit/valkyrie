import Foundation

/// One partition record from a Samsung PIT (Partition Information Table).
///
/// The layout mirrors libpit's `PitEntry`: 132 bytes, little-endian, ending in three
/// fixed-width 32-byte NUL-padded name fields.
struct PitEntry: Identifiable, Hashable {
    static let dataSize = 132
    static let nameFieldLength = 32

    var binaryType: UInt32
    var deviceType: UInt32
    var identifier: UInt32
    var attributes: UInt32
    var updateAttributes: UInt32
    var blockSizeOrOffset: UInt32
    var blockCount: UInt32
    var fileOffset: UInt32
    var fileSize: UInt32
    var partitionName: String
    var flashFilename: String
    var fotaFilename: String

    // Identifiers repeat across some PITs, so pair it with the name for a stable id.
    var id: String { "\(identifier)-\(partitionName)" }

    // libpit: kAttributeWrite = 1, kAttributeSTL = 1 << 1
    var isWritable: Bool { attributes & 0b01 != 0 }
    var usesSTL: Bool { attributes & 0b10 != 0 }

    // libpit: kUpdateAttributeFota = 1, kUpdateAttributeSecure = 1 << 1
    var isFota: Bool { updateAttributes & 0b01 != 0 }
    var isSecure: Bool { updateAttributes & 0b10 != 0 }

    /// Heimdall can only write a partition that names a flash file in the PIT.
    var isFlashable: Bool {
        let name = flashFilename.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name != "-"
    }

    var binaryTypeLabel: String {
        return binaryType == 1 ? "CP" : "AP"
    }

    /// Partitions holding the user's data rather than the OS.
    ///
    /// Writing any of these turns a firmware update into a factory reset. Factory
    /// (`_fac`) firmware ships `userdata.img` and `persist.img` inside AP, so choosing
    /// HOME_CSC over CSC does not protect them — the only thing that does is not
    /// flashing them.
    var isUserDataPartition: Bool {
        let name = partitionName.uppercased()
        return ["USERDATA", "PERSIST", "CACHE", "METADATA", "OMR", "EFS"].contains(name)
    }

    var deviceTypeLabel: String {
        switch deviceType {
        case 0: return "OneNAND"
        case 1: return "FAT"
        case 2: return "MMC"
        case 3: return "All"
        case 8: return "UFS"
        default: return "Type \(deviceType)"
        }
    }
}

enum PitError: LocalizedError {
    case tooSmall(Int)
    case badMagic(UInt32)
    case truncated(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .tooSmall(let n):
            return "File is only \(n) bytes — too small to be a PIT."
        case .badMagic(let m):
            return String(format: "Not a PIT file (magic 0x%08X, expected 0x12349876).", m)
        case .truncated(let expected, let actual):
            return "PIT is truncated — the header declares \(expected) bytes but the file is \(actual)."
        }
    }
}

/// A parsed PIT file. Samsung ships one inside the CSC tarball; the device also
/// holds its own copy, which Heimdall can read over USB.
struct PitData {
    static let magic: UInt32 = 0x1234_9876
    static let headerSize = 28

    var comTar2: String
    var cpuBlId: String
    var luCount: UInt16
    var entries: [PitEntry]

    var flashableEntries: [PitEntry] {
        return entries.filter { $0.isFlashable }
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= PitData.headerSize else {
            throw PitError.tooSmall(bytes.count)
        }

        let magic = PitData.readUInt32(bytes, 0)
        guard magic == PitData.magic else {
            throw PitError.badMagic(magic)
        }

        let count = Int(PitData.readUInt32(bytes, 4))
        // A corrupt count would otherwise walk us off the end of the buffer.
        let required = PitData.headerSize + count * PitEntry.dataSize
        guard count > 0, count < 4096, bytes.count >= required else {
            throw PitError.truncated(expected: required, actual: bytes.count)
        }

        comTar2 = PitData.readString(bytes, 8, 8)
        cpuBlId = PitData.readString(bytes, 16, 8)
        luCount = PitData.readUInt16(bytes, 24)

        var parsed: [PitEntry] = []
        parsed.reserveCapacity(count)
        for index in 0..<count {
            let o = PitData.headerSize + index * PitEntry.dataSize
            parsed.append(PitEntry(
                binaryType: PitData.readUInt32(bytes, o),
                deviceType: PitData.readUInt32(bytes, o + 4),
                identifier: PitData.readUInt32(bytes, o + 8),
                attributes: PitData.readUInt32(bytes, o + 12),
                updateAttributes: PitData.readUInt32(bytes, o + 16),
                blockSizeOrOffset: PitData.readUInt32(bytes, o + 20),
                blockCount: PitData.readUInt32(bytes, o + 24),
                fileOffset: PitData.readUInt32(bytes, o + 28),
                fileSize: PitData.readUInt32(bytes, o + 32),
                partitionName: PitData.readString(bytes, o + 36, PitEntry.nameFieldLength),
                flashFilename: PitData.readString(bytes, o + 68, PitEntry.nameFieldLength),
                fotaFilename: PitData.readString(bytes, o + 100, PitEntry.nameFieldLength)
            ))
        }
        entries = parsed
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    // MARK: - Little-endian readers

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readString(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        var slice: [UInt8] = []
        slice.reserveCapacity(length)
        for i in offset..<min(offset + length, bytes.count) {
            if bytes[i] == 0 { break }
            slice.append(bytes[i])
        }
        let text = String(decoding: slice, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
