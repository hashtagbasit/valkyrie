import Foundation

/// Command line tools shipped inside the app bundle.
///
/// Valkyrie drives two external binaries — the flash engine and the lz4 decompressor.
/// Asking people to build those themselves before they can use a GUI defeats the point,
/// so both travel in `Contents/Resources/bin` along with the one library the engine
/// needs. The engine is relinked at build time to load that library from beside itself
/// rather than from Homebrew.
enum BundledTools {
    static func path(for tool: String) -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("bin/\(tool)").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// True when the app is self-contained and needs nothing installed.
    static var isSelfContained: Bool {
        return path(for: "heimdall") != nil && path(for: "lz4") != nil
    }
}
