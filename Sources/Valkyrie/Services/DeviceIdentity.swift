import Foundation
import AppKit

/// Reads the model and region straight off a connected phone.
///
/// Typing a model code and a three-letter CSC by hand is the easiest place to get a
/// firmware download wrong, and flashing the wrong region is a real way to break a phone.
/// When the device is booted with USB debugging on, adb can simply be asked.
enum DeviceIdentity {
    struct Identity {
        let model: String
        let region: String
        let currentBuild: String?
    }

    private static let adbCandidates = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
    ]

    static func locateADB() -> String? {
        return adbCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { locateADB() != nil }

    private static func property(_ adb: String, _ key: String) async -> String? {
        let result = try? await CommandRunner().run(
            executable: adb,
            arguments: ["shell", "getprop", key]
        )
        let value = result?.output
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, !value.contains("no devices"), !value.contains("error:") else {
            return nil
        }
        return value
    }

    /// Returns nil when no debuggable device is attached — download mode has no adb,
    /// so this only works before the phone is put into it.
    static func detect() async -> Identity? {
        guard let adb = locateADB() else { return nil }

        let devices = try? await CommandRunner().run(executable: adb, arguments: ["devices"])
        let attached = (devices?.output ?? "")
            .split(separator: "\n")
            .dropFirst()
            .contains { $0.contains("\tdevice") }
        guard attached else { return nil }

        guard let model = await property(adb, "ro.product.model"),
              let region = await property(adb, "ro.csc.sales_code") else {
            return nil
        }
        return Identity(
            model: model.uppercased(),
            region: region.uppercased(),
            currentBuild: await property(adb, "ro.build.PDA")
        )
    }
}
