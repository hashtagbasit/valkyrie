import Foundation
import AppKit

@MainActor
final class ToolsModel: ObservableObject {
    @Published private(set) var pit: PitData?
    @Published private(set) var pitSource: String?
    @Published private(set) var isReading = false
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false
    @Published var needsAuthentication = false
    @Published private(set) var deviceInfo: String?
    @Published private(set) var isRunningAction = false

    func openPitFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open PIT"
        panel.message = "Choose a .pit file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url, source: url.lastPathComponent)
    }

    func load(url: URL, source: String) {
        do {
            pit = try PitData(contentsOf: url)
            pitSource = source
            message = "Loaded \(pit?.entries.count ?? 0) entries from \(source)"
            messageIsError = false
        } catch {
            pit = nil
            pitSource = nil
            message = error.localizedDescription
            messageIsError = true
        }
    }

    /// Pulls the partition table straight off the phone. This is also the safest way
    /// to prove the USB path works — it reads, and writes nothing.
    func readFromDevice() async {
        guard !isReading else { return }

        guard PrivilegeBroker.hasPassword else {
            needsAuthentication = true
            return
        }
        guard let heimdall = FlashController.locateHeimdall() else {
            message = "Flash engine not found. See the README for setup."
            messageIsError = true
            return
        }

        isReading = true
        message = "Reading partition table from the device…"
        messageIsError = false
        defer { isReading = false }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("valkyrie-device-\(UUID().uuidString.prefix(8)).pit")

        do {
            let result = try await CommandRunner().run(
                executable: heimdall,
                arguments: ["download-pit", "--output", destination.path, "--no-reboot"],
                elevated: true,
                stdin: PrivilegeBroker.password()
            )
            guard result.succeeded, FileManager.default.fileExists(atPath: destination.path) else {
                let tail = result.output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { EngineOutputFilter.isDisplayable($0) }
                    .suffix(3)
                    .joined(separator: " · ")
                message = tail.isEmpty ? "Could not read the partition table from the device." : tail
                messageIsError = true
                return
            }
            load(url: destination, source: "the connected device")
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    /// Runs an engine action that needs root, returning its output.
    private func runEngineAction(_ arguments: [String], describing label: String) async -> String? {
        guard PrivilegeBroker.hasPassword else {
            needsAuthentication = true
            return nil
        }
        guard let heimdall = FlashController.locateHeimdall() else {
            message = "Flash engine not found. See the README for setup."
            messageIsError = true
            return nil
        }

        isRunningAction = true
        message = "\(label)…"
        messageIsError = false
        defer { isRunningAction = false }

        do {
            let result = try await CommandRunner().run(
                executable: heimdall,
                arguments: arguments,
                elevated: true,
                stdin: PrivilegeBroker.password()
            )
            let text = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { EngineOutputFilter.isDisplayable($0) }
                .joined(separator: "\n")

            if result.succeeded {
                message = "\(label) completed."
                messageIsError = false
            } else {
                message = text.isEmpty ? "\(label) failed." : text
                messageIsError = true
            }
            return text
        } catch {
            message = error.localizedDescription
            messageIsError = true
            return nil
        }
    }

    /// Clears the "connect phone to PC" screen some devices get stuck on.
    func closePCScreen() async {
        _ = await runEngineAction(["close-pc-screen", "--no-reboot"], describing: "Clearing the PC screen")
    }

    /// Dumps the USB descriptors the device reports.
    func readDeviceInfo() async {
        if let text = await runEngineAction(["info"], describing: "Reading device info"), !text.isEmpty {
            deviceInfo = text
        }
    }

    func authenticate(password: String) async -> Bool {
        let ok = await PrivilegeBroker.validateAndStore(password)
        if ok {
            needsAuthentication = false
            await readFromDevice()
        }
        return ok
    }

    func clear() {
        pit = nil
        pitSource = nil
        message = nil
    }
}
