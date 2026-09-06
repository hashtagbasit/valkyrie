import Foundation
import AppKit

enum FlashState: Equatable {
    case idle
    case preparing
    case ready
    case flashing
    case succeeded
    case failed(String)

    var isBusy: Bool {
        return self == .preparing || self == .flashing
    }
}

struct LogLine: Identifiable {
    enum Kind {
        case info, success, error, command
    }

    let id = UUID()
    let text: String
    let kind: Kind
}

/// Drives the whole flash: discovering a firmware folder, unpacking it, mapping
/// partitions, and running Heimdall while tracking where it's up to.
@MainActor
final class FlashController: ObservableObject {
    @Published private(set) var state: FlashState = .idle
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var plan: [FlashPlanEntry] = []
    @Published private(set) var currentPartition: String?
    @Published private(set) var currentPercent: Int = 0
    @Published private(set) var completedPartitions: [String] = []
    @Published private(set) var statusText = "No firmware loaded"
    @Published private(set) var pit: PitData?
    @Published private(set) var extractedWorkDirectory: URL?
    @Published private(set) var pitURL: URL?

    @Published var package: FirmwarePackage?
    @Published var selectedSlots: Set<FirmwareSlot> = []
    @Published var options = FlashOptions()

    private let extractor = FirmwareExtractor()
    private var runner: CommandRunner?
    private let powerAssertion = PowerAssertion(reason: "Flashing firmware")

    private static let heimdallCandidates = [
        "/opt/homebrew/bin/heimdall",
        "/usr/local/bin/heimdall",
        "/usr/bin/heimdall",
    ]

    /// Prefers the copy shipped inside the app.
    ///
    /// Requiring people to clone a repo, install four Homebrew packages and compile C++
    /// before they can flash a phone rules out most of the people this is for. The engine
    /// and its one library travel with the bundle instead; the system paths stay as a
    /// fallback so a development build still works without assembling the app.
    static func locateHeimdall() -> String? {
        if let bundled = BundledTools.path(for: "heimdall") { return bundled }
        return heimdallCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var enabledPlan: [FlashPlanEntry] {
        return plan.filter { $0.isEnabled }
    }

    /// Completed partitions plus the fraction of the one in flight.
    var overallProgress: Double {
        let total = enabledPlan.count
        guard total > 0 else { return 0 }
        let done = Double(completedPartitions.count)
        let inFlight = currentPartition == nil ? 0 : Double(currentPercent) / 100.0
        return min(1.0, (done + inFlight) / Double(total))
    }

    /// Partitions in the current plan that would destroy user data.
    var destructivePartitions: [FlashPlanEntry] {
        return enabledPlan.filter { $0.pitEntry.isUserDataPartition }
    }

    /// Derived from the actual plan, not from the CSC choice — factory firmware carries
    /// `userdata` in AP, so the CSC variant says nothing about whether data survives.
    var wipesUserData: Bool {
        return !destructivePartitions.isEmpty
    }

    func setEnabled(_ enabled: Bool, forPartition id: String) {
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[index].isEnabled = enabled
    }

    // MARK: - Loading

    func loadPackage(at directory: URL) {
        let found = FirmwarePackage.discover(in: directory)
        package = found
        plan = []
        pit = nil
        completedPartitions = []
        currentPartition = nil
        currentPercent = 0

        guard !found.isEmpty else {
            state = .failed("No firmware tarballs found in \(directory.lastPathComponent).")
            statusText = "Nothing to flash"
            append("No BL/AP/CP/CSC files in \(directory.path)", kind: .error)
            return
        }

        // Default to a data-preserving set: prefer HOME_CSC when the firmware ships one.
        var defaults: Set<FirmwareSlot> = []
        for archive in found.archives where !archive.slot.isCSCVariant {
            defaults.insert(archive.slot)
        }
        if found.archive(for: .homeCSC) != nil {
            defaults.insert(.homeCSC)
        } else if found.archive(for: .csc) != nil {
            defaults.insert(.csc)
        }
        defaults.remove(.userdata)
        selectedSlots = defaults

        state = .idle
        statusText = "\(found.archives.count) files · \(ByteCountFormatter.string(fromByteCount: found.totalSize, countStyle: .file))"
        append("Loaded \(directory.lastPathComponent)", kind: .info)
        for archive in found.archives {
            append("  \(archive.slot.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(archive.filename)  (\(archive.formattedSize))", kind: .info)
        }
        if let build = found.buildVersion {
            append("Build \(build)", kind: .info)
        }
    }

    // MARK: - Preparation

    func prepare() async {
        guard let package else { return }
        guard !selectedSlots.isEmpty else {
            state = .failed("Select at least one firmware file.")
            return
        }

        state = .preparing
        completedPartitions = []
        currentPartition = nil
        currentPercent = 0

        do {
            if options.verifyChecksums {
                append("Verifying checksums before unpacking.", kind: .command)
                let flag = CancellationFlag()
                for archive in package.archives where selectedSlots.contains(archive.slot) {
                    statusText = "Verifying \(archive.filename)"
                    let url = archive.url
                    try await Task.detached(priority: .userInitiated) { [weak self] in
                        _ = try ArchiveVerifier.verify(
                            url: url,
                            isCancelled: { flag.isCancelled },
                            progress: { done, total in
                                guard total > 0 else { return }
                                let percent = Int(Double(done) / Double(total) * 100)
                                Task { @MainActor in
                                    self?.statusText = "Verifying \(url.lastPathComponent) — \(percent)%"
                                }
                            }
                        )
                    }.value
                    append("  checksum OK — \(archive.filename)", kind: .success)
                }
            }

            append("Unpacking firmware — this takes a few minutes for a full set.", kind: .command)
            let output = try await extractor.extract(package: package, slots: selectedSlots) { [weak self] message in
                Task { @MainActor in
                    self?.statusText = message
                    self?.append(message, kind: .info)
                }
            }
            plan = output.plan
            pit = output.pit
            extractedWorkDirectory = output.workDirectory
            pitURL = output.pitURL

            guard !plan.isEmpty else {
                state = .failed("No image matched any partition in the PIT.")
                append("Nothing to flash — no extracted image matched a PIT entry.", kind: .error)
                return
            }

            state = .ready
            statusText = "\(plan.count) partitions ready"
            append("Mapped \(plan.count) partitions from \(output.pitURL.lastPathComponent)", kind: .success)
            for entry in plan {
                let mark = entry.isEnabled ? " " : "·"
                let flag = entry.pitEntry.isUserDataPartition ? "   [USER DATA — deselected]" : ""
                append("\(mark) \(entry.partitionName) ← \(entry.image.filename)  (\(entry.image.formattedSize))\(flag)", kind: entry.pitEntry.isUserDataPartition ? .error : .info)
            }
            let skipped = plan.filter { !$0.isEnabled }
            if !skipped.isEmpty {
                append("Skipping \(skipped.map { $0.partitionName }.joined(separator: ", ")) to preserve user data. Tick them explicitly to wipe.", kind: .success)
            }
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "Preparation failed"
            append(error.localizedDescription, kind: .error)
        }
    }

    // MARK: - Flashing

    func flash() async {
        guard state == .ready, !enabledPlan.isEmpty else { return }
        guard let heimdall = FlashController.locateHeimdall() else {
            state = .failed("Flash engine not found. See the README for setup — it belongs in /opt/homebrew/bin.")
            return
        }

        state = .flashing
        // Never let the machine idle-sleep mid-write.
        powerAssertion.acquire()
        defer { powerAssertion.release() }
        completedPartitions = []
        currentPartition = nil
        currentPercent = 0

        var arguments = ["flash"]
        for entry in enabledPlan {
            arguments += ["--\(entry.partitionName)", entry.image.url.path]
        }
        // Repartitioning rewrites the partition table itself, so Heimdall requires
        // the PIT to be passed explicitly alongside it.
        if options.repartition, let pitURL {
            arguments += ["--repartition", "--pit", pitURL.path]
        }
        if !options.autoReboot { arguments.append("--no-reboot") }
        if options.resume { arguments.append("--resume") }
        if options.tFlash { arguments.append("--tflash") }
        if options.skipSizeCheck { arguments.append("--skip-size-check") }
        if options.verbose { arguments.append("--verbose") }

        append("\u{203A} flash \(arguments.dropFirst().joined(separator: " "))", kind: .command)

        let buffer = TerminalBuffer()
        var parser = FlashProgressParser()
        let runner = CommandRunner()
        self.runner = runner

        do {
            let result = try await runner.run(
                executable: heimdall,
                arguments: arguments,
                elevated: true,
                stdin: PrivilegeBroker.password()
            ) { chunk in
                let completed = buffer.feed(chunk)
                let partial = buffer.currentLine
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for line in completed {
                        parser.consume(line: line)
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if EngineOutputFilter.isDisplayable(trimmed) {
                            self.append(trimmed, kind: trimmed.hasPrefix("ERROR:") ? .error : .info)
                        }
                    }
                    parser.consume(partialLine: partial)
                    self.currentPartition = parser.currentPartition
                    self.currentPercent = parser.currentPercent
                    self.completedPartitions = parser.completedPartitions
                    if let partition = parser.currentPartition {
                        self.statusText = "Writing \(partition) — \(parser.currentPercent)%"
                    }
                }
            }

            buffer.flush()
            self.runner = nil

            if result.succeeded && parser.errors.isEmpty {
                state = .succeeded
                currentPartition = nil
                statusText = options.autoReboot
                    ? "Flash complete — the phone is rebooting"
                    : "Flash complete — the phone is still in download mode"
                append("Flash completed successfully.", kind: .success)
                CompletionAlert.signal(success: true)
                if options.autoReboot {
                    append("First boot after a full flash takes several minutes. Let it sit.", kind: .info)
                }
            } else {
                let detail = parser.errors.last ?? "The flash engine exited with code \(result.exitCode)."
                state = .failed(detail)
                statusText = "Flash failed"
                append(detail, kind: .error)
                CompletionAlert.signal(success: false)
            }
        } catch {
            self.runner = nil
            state = .failed(error.localizedDescription)
            statusText = "Flash failed"
            append(error.localizedDescription, kind: .error)
        }
    }

    func cancel() {
        runner?.cancel()
        append("Cancel requested — interrupting a flash mid-write can leave the phone unbootable.", kind: .error)
    }

    func reset() {
        state = plan.isEmpty ? .idle : .ready
        currentPartition = nil
        currentPercent = 0
        completedPartitions = []
    }

    func clearLog() {
        log = []
    }

    /// The log as plain text, for saving alongside a flash.
    var logText: String {
        return log.map { $0.text }.joined(separator: "\n")
    }

    func exportLog() {
        guard !log.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "valkyrie-flash-log.txt"
        panel.prompt = "Save Log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? logText.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ text: String, kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        // Keep the log bounded; a verbose flash emits a lot of lines.
        if log.count > 2000 {
            log.removeFirst(log.count - 2000)
        }
    }
}
