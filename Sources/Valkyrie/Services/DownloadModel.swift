import Foundation
import AppKit

/// Shared cancel signal readable from the decryption thread.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}

enum DownloadPhase: Equatable {
    case idle
    case preparing
    case downloading
    case decrypting
    case unpacking
    case finished
    case failed(String)

    var isBusy: Bool {
        return self == .preparing || self == .downloading || self == .decrypting || self == .unpacking
    }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var model = ""
    @Published var region = ""
    @Published private(set) var isChecking = false
    @Published private(set) var info: FirmwareVersionInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isDetecting = false
    @Published private(set) var detectedBuild: String?

    @Published private(set) var phase: DownloadPhase = .idle
    @Published private(set) var binary: FusBinaryInfo?
    @Published private(set) var bytesReceived: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var finishedURL: URL?
    @Published var keepIntermediateFiles = false
    @Published private(set) var firmwareDirectory: URL?

    private let client = FusClient()
    private let powerAssertion = PowerAssertion(reason: "Downloading firmware")
    private var downloader: ResumableDownloader?
    private var job: Task<Void, Never>?
    private let cancelFlag = CancellationFlag()

    /// Region codes worth offering up front. Samsung has many more.
    static let commonRegions = [
        "EUX", "EUY", "BTU", "DBT", "XEF", "ITV", "PHE", "XEO",
        "OXM", "INS", "XSA", "XSP", "ATO", "TPA", "ZTO", "CHC",
    ]

    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    var formattedRate: String {
        guard bytesPerSecond > 1 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    var estimatedTimeRemaining: String {
        guard bytesPerSecond > 1, totalBytes > bytesReceived else { return "" }
        let seconds = Double(totalBytes - bytesReceived) / bytesPerSecond
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? ""
    }

    // MARK: - Version lookup

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            info = try await FusVersionService.fetch(model: model, region: region)
        } catch {
            info = nil
            errorMessage = error.localizedDescription
        }
    }

    func mirrorURL(for build: FirmwareBuild) -> URL? {
        let model = model.trimmingCharacters(in: .whitespaces).uppercased()
        let region = region.trimmingCharacters(in: .whitespaces).uppercased()
        return URL(string: "https://samfw.com/firmware/\(model)/\(region)/\(build.ap)")
    }

    /// Fills in model and region from the attached phone, so neither has to be typed.
    func detectFromDevice() async {
        guard !isDetecting else { return }
        isDetecting = true
        errorMessage = nil
        defer { isDetecting = false }

        guard let identity = await DeviceIdentity.detect() else {
            errorMessage = DeviceIdentity.isAvailable
                ? "No phone with USB debugging available. Connect it booted into Android, with USB debugging on and this Mac authorised."
                : "adb isn't installed — `brew install --cask android-platform-tools` to detect automatically."
            return
        }
        model = identity.model
        region = identity.region
        detectedBuild = identity.currentBuild
        await check()
    }

    // MARK: - Download

    func start(build: FirmwareBuild, into directory: URL) {
        guard !phase.isBusy else { return }
        cancelFlag.reset()
        finishedURL = nil
        job = Task { await run(build: build, directory: directory) }
    }

    func cancel() {
        cancelFlag.cancel()
        downloader?.cancel()
        job?.cancel()
        phase = .idle
        statusText = "Cancelled"
    }

    private func run(build: FirmwareBuild, directory: URL) async {
        let modelCode = model.trimmingCharacters(in: .whitespaces).uppercased()
        let regionCode = region.trimmingCharacters(in: .whitespaces).uppercased()

        powerAssertion.acquire()
        defer { powerAssertion.release() }

        do {
            phase = .preparing
            statusText = AuthParamStore.isCached
                ? "Authenticating with Samsung…"
                : "Fetching authentication data…"
            try await client.generateNonce()

            statusText = "Requesting firmware details…"
            let binaryInfo = try await client.binaryInform(
                version: build.display, model: modelCode, region: regionCode
            )
            binary = binaryInfo
            totalBytes = binaryInfo.byteSize

            statusText = "Initialising download…"
            try await client.binaryInit(info: binaryInfo)

            let encryptedURL = directory.appendingPathComponent(binaryInfo.fileName)
            var existing: Int64 = 0
            if let attributes = try? FileManager.default.attributesOfItem(atPath: encryptedURL.path),
               let size = attributes[.size] as? Int64 {
                existing = size
            }

            if existing < binaryInfo.byteSize {
                phase = .downloading
                statusText = existing > 0 ? "Resuming download…" : "Downloading…"
                try await downloadWithRetry(info: binaryInfo, to: encryptedURL)
            } else {
                bytesReceived = existing
            }

            if cancelFlag.isCancelled { return }

            let attributes = try? FileManager.default.attributesOfItem(atPath: encryptedURL.path)
            let onDisk = (attributes?[.size] as? Int64) ?? 0
            guard onDisk >= binaryInfo.byteSize else {
                throw FusError.sizeMismatch(expected: binaryInfo.byteSize, actual: onDisk)
            }

            guard binaryInfo.isEncrypted else {
                finish(at: encryptedURL)
                return
            }

            phase = .decrypting
            statusText = "Decrypting…"
            bytesReceived = 0
            bytesPerSecond = 0

            let decryptedURL = directory.appendingPathComponent(binaryInfo.decryptedName)
            let key = binaryInfo.decryptionKey
            let size = binaryInfo.byteSize
            let flag = cancelFlag

            let checksum = try await Task.detached(priority: .userInitiated) { [weak self] () -> UInt32 in
                return try FirmwareDecryptor.decrypt(
                    source: encryptedURL,
                    destination: decryptedURL,
                    key: key,
                    totalBytes: size,
                    isCancelled: { flag.isCancelled },
                    progress: { done, total in
                        Task { @MainActor in
                            self?.bytesReceived = done
                            self?.totalBytes = total
                        }
                    }
                )
            }.value

            if cancelFlag.isCancelled { return }

            // Samsung publishes the CRC of the encrypted archive, so a corrupt transfer
            // is caught here rather than discovered halfway through flashing a phone.
            if let expected = UInt32(binaryInfo.crc), expected != checksum {
                throw FusError.checksumMismatch(expected: expected, actual: checksum)
            }

            if !keepIntermediateFiles {
                try? FileManager.default.removeItem(at: encryptedURL)
            }

            phase = .unpacking
            statusText = "Unpacking archive…"
            let folder = directory.appendingPathComponent(binaryInfo.folderName, isDirectory: true)
            try await unpack(archive: decryptedURL, into: folder)

            if !keepIntermediateFiles {
                try? FileManager.default.removeItem(at: decryptedURL)
            }

            firmwareDirectory = folder
            finish(at: folder)
        } catch is CancellationError {
            phase = .idle
            statusText = "Cancelled"
        } catch {
            phase = .failed(error.localizedDescription)
            statusText = "Failed"
            CompletionAlert.signal(success: false)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    /// Downloads with automatic resume across dropped connections.
    ///
    /// A 20GB transfer over half an hour will lose its connection sooner or later, and
    /// the session almost always dies with it — a resumed range request carrying stale
    /// credentials comes back 401. So each retry re-authenticates from scratch and then
    /// picks up from whatever is already on disk.
    private func downloadWithRetry(info: FusBinaryInfo, to destination: URL) async throws {
        let maxAttempts = 10
        var attempt = 0
        var current = info

        while true {
            if cancelFlag.isCancelled { throw CancellationError() }

            let existing = DownloadModel.fileSize(at: destination)
            if existing >= current.byteSize { return }

            var request = URLRequest(url: await client.downloadURL(for: current))
            for (key, value) in await client.downloadHeaders() {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if existing > 0 {
                request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            }

            let downloader = ResumableDownloader { [weak self] received, total, rate in
                Task { @MainActor in
                    self?.bytesReceived = received
                    self?.totalBytes = total
                    self?.bytesPerSecond = rate
                }
            }
            self.downloader = downloader

            do {
                try await downloader.download(
                    request: request, to: destination, existing: existing, total: current.byteSize
                )
                self.downloader = nil
                return
            } catch is CancellationError {
                self.downloader = nil
                throw CancellationError()
            } catch {
                self.downloader = nil
                attempt += 1
                guard attempt <= maxAttempts, !cancelFlag.isCancelled else { throw error }

                let done = DownloadModel.fileSize(at: destination)
                let percent = current.byteSize > 0
                    ? Int(Double(done) / Double(current.byteSize) * 100)
                    : 0
                statusText = "Connection lost at \(percent)% — reconnecting (\(attempt)/\(maxAttempts))…"
                bytesPerSecond = 0

                // Back off, but not so far that a long stall wastes the whole window.
                let delay = min(30.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if cancelFlag.isCancelled { throw CancellationError() }

                // Re-establish the session before resuming.
                do {
                    try await client.generateNonce()
                    current = try await client.binaryInform(
                        version: current.version, model: current.model, region: current.region
                    )
                    try await client.binaryInit(info: current)
                    binary = current
                } catch {
                    // Leave it to the next iteration; it will try again after a backoff.
                }
            }
        }
    }

    /// Uses ditto rather than unzip: firmware archives are well past 4GB, and ditto
    /// handles Zip64 correctly where the stock unzip does not.
    private func unpack(archive: URL, into folder: URL) async throws {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try await CommandRunner().run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path, folder.path]
        )
        guard result.succeeded else {
            let tail = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(2)
                .joined(separator: " · ")
            throw FusError.unpackFailed(tail.isEmpty ? "ditto exited with \(result.exitCode)" : tail)
        }
    }

    private func finish(at url: URL) {
        finishedURL = url
        phase = .finished
        CompletionAlert.signal(success: true)
        statusText = "Ready — \(url.lastPathComponent)"
    }

    func revealInFinder() {
        guard let finishedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finishedURL])
    }
}
