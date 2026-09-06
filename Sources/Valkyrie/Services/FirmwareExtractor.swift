import Foundation

struct ExtractedImage: Identifiable, Hashable {
    let url: URL
    let byteSize: Int64

    var id: URL { url }
    var filename: String { url.lastPathComponent }
    var formattedSize: String {
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// A partition Heimdall will write, paired with the image that fills it.
struct FlashPlanEntry: Identifiable, Hashable {
    let partitionName: String
    let image: ExtractedImage
    let pitEntry: PitEntry
    var isEnabled: Bool = true

    var id: String { partitionName }
}

enum ExtractionError: LocalizedError {
    case noArchivesSelected
    case lz4Missing
    case commandFailed(tool: String, file: String, output: String)
    case noPitFound

    var errorDescription: String? {
        switch self {
        case .noArchivesSelected:
            return "No firmware files selected."
        case .lz4Missing:
            return "The lz4 decompressor is missing from this build. Reinstall Valkyrie, or install it with `brew install lz4`."
        case .commandFailed(let tool, let file, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = detail.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "\(tool) failed on \(file).\n\(tail)"
        case .noPitFound:
            return "No .pit file found. The partition table normally ships inside the CSC tarball — make sure a CSC or HOME_CSC file is selected."
        }
    }
}

/// Unpacks a firmware set and works out which image belongs to which partition.
///
/// The mapping comes from the PIT that ships inside the CSC tarball: each entry names
/// both a partition and the file that fills it, so a file on disk matching an entry's
/// flash filename is what gets written there. This is the same rule `flash-firmware.sh`
/// applies, but read from the PIT binary directly rather than scraped from CLI output.
final class FirmwareExtractor {
    static let workDirectoryName = ".valkyrie-work"

    private static let lz4Candidates = [
        "/opt/homebrew/bin/lz4",
        "/usr/local/bin/lz4",
        "/usr/bin/lz4",
    ]

    static func locateLZ4() -> String? {
        if let bundled = BundledTools.path(for: "lz4") { return bundled }
        return lz4Candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Output {
        let workDirectory: URL
        let images: [ExtractedImage]
        let pit: PitData
        let pitURL: URL
        let plan: [FlashPlanEntry]
    }

    private let runner = CommandRunner()

    func extract(
        package: FirmwarePackage,
        slots: Set<FirmwareSlot>,
        onProgress: @escaping (String) -> Void
    ) async throws -> Output {
        let archives = package.archives.filter { slots.contains($0.slot) }
        guard !archives.isEmpty else { throw ExtractionError.noArchivesSelected }

        let work = package.directory.appendingPathComponent(FirmwareExtractor.workDirectoryName)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        for archive in archives {
            // Unpacking AP alone is ~24GB; a marker keeps a second run cheap.
            let marker = work.appendingPathComponent(".extracted-\(archive.filename)")
            if FileManager.default.fileExists(atPath: marker.path) {
                onProgress("Already unpacked \(archive.filename)")
                continue
            }
            onProgress("Extracting \(archive.filename)")
            let result = try await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-xf", archive.url.path, "-C", work.path]
            )
            guard result.succeeded else {
                throw ExtractionError.commandFailed(
                    tool: "tar", file: archive.filename, output: result.output
                )
            }
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }

        let compressed = try FileManager.default
            .contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lz4" }

        if !compressed.isEmpty {
            guard let lz4 = FirmwareExtractor.locateLZ4() else { throw ExtractionError.lz4Missing }
            for source in compressed {
                let destination = source.deletingPathExtension()
                // Decompressing SUPER takes a while; don't redo it on a second run.
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                onProgress("Decompressing \(source.lastPathComponent)")
                let result = try await runner.run(
                    executable: lz4,
                    arguments: ["-d", "-q", "-f", source.path, destination.path]
                )
                guard result.succeeded else {
                    throw ExtractionError.commandFailed(
                        tool: "lz4", file: source.lastPathComponent, output: result.output
                    )
                }
                // The compressed copy is dead weight once decompressed, and a full set
                // of them is another ~20GB sitting next to the images.
                try? FileManager.default.removeItem(at: source)
            }
        }

        onProgress("Reading partition table")
        try await ensurePit(in: work, package: package, onProgress: onProgress)

        let contents = try FileManager.default.contentsOfDirectory(
            at: work,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        guard let pitURL = contents.first(where: { $0.pathExtension == "pit" }) else {
            throw ExtractionError.noPitFound
        }
        let pit = try PitData(contentsOf: pitURL)

        var images: [ExtractedImage] = []
        for url in contents {
            guard url.pathExtension != "lz4", url.pathExtension != "pit" else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            images.append(ExtractedImage(url: url, byteSize: Int64(values?.fileSize ?? 0)))
        }

        var plan: [FlashPlanEntry] = []
        for entry in pit.flashableEntries {
            guard let image = images.first(where: { $0.filename == entry.flashFilename }) else { continue }
            // Data partitions start deselected: a firmware update should not wipe the
            // phone unless the user explicitly asks for it.
            plan.append(FlashPlanEntry(
                partitionName: entry.partitionName,
                image: image,
                pitEntry: entry,
                isEnabled: !entry.isUserDataPartition
            ))
        }

        return Output(workDirectory: work, images: images, pit: pit, pitURL: pitURL, plan: plan)
    }

    /// Makes sure a PIT is present in the work directory.
    ///
    /// Only the full CSC archive carries the partition table — HOME_CSC omits it. Since
    /// Valkyrie defaults to HOME_CSC to preserve user data, the table has to be sourced
    /// from whichever archive actually has one. Just the .pit entry is extracted, never
    /// the rest of that archive: CSC also carries images (omr) that HOME_CSC
    /// deliberately leaves out, and unpacking them would silently widen the flash.
    private func ensurePit(
        in work: URL,
        package: FirmwarePackage,
        onProgress: @escaping (String) -> Void
    ) async throws {
        let existing = try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        if existing?.contains(where: { $0.pathExtension.lowercased() == "pit" }) == true { return }

        // Cheapest archives first; AP is enormous and never holds the table.
        let order: [FirmwareSlot] = [.csc, .homeCSC, .bootloader, .modem, .userdata, .ap]
        let candidates = order.compactMap { slot in package.archives.first { $0.slot == slot } }

        for archive in candidates {
            let listing = try await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-tf", archive.url.path]
            )
            guard listing.succeeded else { continue }
            let entry = listing.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.lowercased().hasSuffix(".pit") }
            guard let entry else { continue }

            onProgress("Taking \(entry) from \(archive.slot.rawValue)")
            let extracted = try await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-xf", archive.url.path, "-C", work.path, entry]
            )
            if extracted.succeeded { return }
        }
    }

    /// Removes the unpacked images. They're large — a full set is roughly the size
    /// of the firmware again — so make it easy to reclaim the space.
    static func cleanUp(package: FirmwarePackage) throws {
        let work = package.directory.appendingPathComponent(workDirectoryName)
        guard FileManager.default.fileExists(atPath: work.path) else { return }
        try FileManager.default.removeItem(at: work)
    }

    static func workDirectorySize(for package: FirmwarePackage) -> Int64 {
        let work = package.directory.appendingPathComponent(workDirectoryName)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: work, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
