import Foundation

/// One of the tarballs that make up a stock Samsung firmware set.
enum FirmwareSlot: String, CaseIterable, Identifiable {
    case bootloader = "BL"
    case ap = "AP"
    case modem = "CP"
    case csc = "CSC"
    case homeCSC = "HOME_CSC"
    case userdata = "USERDATA"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bootloader: return "Bootloader"
        case .ap: return "System"
        case .modem: return "Modem"
        case .csc: return "CSC"
        case .homeCSC: return "HOME_CSC"
        case .userdata: return "Userdata"
        }
    }

    var detail: String {
        switch self {
        case .bootloader: return "Boot chain and secure world"
        case .ap: return "Android system — factory builds also carry userdata"
        case .modem: return "Baseband / radio"
        case .csc: return "Region config — the wiping variant"
        case .homeCSC: return "Region config — the non-wiping variant"
        case .userdata: return "Optional data image"
        }
    }

    /// CSC and HOME_CSC are mutually exclusive: they write the same partitions.
    var isCSCVariant: Bool {
        return self == .csc || self == .homeCSC
    }

    var wipesUserData: Bool {
        return self == .csc
    }

    var sortOrder: Int {
        switch self {
        case .bootloader: return 0
        case .ap: return 1
        case .modem: return 2
        case .csc: return 3
        case .homeCSC: return 4
        case .userdata: return 5
        }
    }

    /// Matches a firmware filename to its slot. `HOME_CSC_` is checked as its own
    /// prefix so it never collapses into `CSC`.
    static func matching(filename: String) -> FirmwareSlot? {
        let upper = filename.uppercased()
        for slot in [FirmwareSlot.homeCSC, .bootloader, .ap, .modem, .csc, .userdata] {
            if upper.hasPrefix(slot.rawValue + "_") { return slot }
        }
        return nil
    }
}

struct FirmwareArchive: Identifiable, Hashable {
    let slot: FirmwareSlot
    let url: URL
    let byteSize: Int64

    var id: URL { url }
    var filename: String { url.lastPathComponent }

    var formattedSize: String {
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// A folder of stock firmware tarballs, as downloaded and unzipped.
struct FirmwarePackage {
    let directory: URL
    var archives: [FirmwareArchive]

    var isEmpty: Bool { archives.isEmpty }

    var totalSize: Int64 {
        return archives.reduce(0) { $0 + $1.byteSize }
    }

    func archive(for slot: FirmwareSlot) -> FirmwareArchive? {
        return archives.first { $0.slot == slot }
    }

    /// Samsung names files `AP_<build>_<build>_<factory>_REV..`, so the build string
    /// is the second underscore-separated field.
    var buildVersion: String? {
        guard let reference = archives.first(where: { $0.slot == .ap }) ?? archives.first else { return nil }
        let parts = reference.filename.split(separator: "_")
        guard parts.count > 1 else { return nil }
        let candidate = String(parts[1])
        return candidate.count >= 8 ? candidate : nil
    }

    /// The model code is the leading letters+digits of the build string (e.g. F956B).
    var modelCode: String? {
        guard let build = buildVersion else { return nil }
        // Build strings look like F956BXXS4DZH5 — the model runs up to the "XX"/"OXM" marker.
        if let range = build.range(of: "XX") ?? build.range(of: "OXM") {
            return String(build[build.startIndex..<range.lowerBound])
        }
        return nil
    }

    static func discover(in directory: URL) -> FirmwarePackage {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var found: [FirmwareArchive] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasSuffix(".tar.md5") || name.hasSuffix(".tar") else { continue }
            guard let slot = FirmwareSlot.matching(filename: name) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            found.append(FirmwareArchive(slot: slot, url: url, byteSize: Int64(size)))
        }
        found.sort { $0.slot.sortOrder < $1.slot.sortOrder }
        return FirmwarePackage(directory: directory, archives: found)
    }
}

/// Options mirroring Odin's checkbox row, plus the two Heimdall-specific ones.
struct FlashOptions: Equatable {
    var autoReboot = true
    var repartition = false
    var tFlash = false
    var skipSizeCheck = false
    var resume = false
    var verbose = true
    var verifyChecksums = true
}
