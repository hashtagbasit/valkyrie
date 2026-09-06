import Foundation

/// Reassembles a pty byte stream into display lines.
///
/// Heimdall repaints its percentage counter with backspaces — it prints `0%`, then
/// `\b\b45%` — so naively appending chunks produces `0%1%2%3%45%`. This applies
/// backspace and carriage-return semantics the way a terminal would, which gives
/// both a clean log and an accurate reading of the current percentage.
final class TerminalBuffer {
    private(set) var lines: [String] = []
    private var current = ""

    var currentLine: String { current }

    /// Feeds a chunk and returns the lines it completed. The still-open line is
    /// available separately via `currentLine`.
    @discardableResult
    func feed(_ chunk: String) -> [String] {
        var completed: [String] = []
        for character in chunk {
            switch character {
            case "\n":
                completed.append(current)
                lines.append(current)
                current = ""
            case "\r":
                current = ""
            case "\u{08}":
                if !current.isEmpty { current.removeLast() }
            default:
                current.append(character)
            }
        }
        return completed
    }

    /// Commits any partial line, e.g. after the process exits.
    @discardableResult
    func flush() -> String? {
        guard !current.isEmpty else { return nil }
        let line = current
        lines.append(line)
        current = ""
        return line
    }
}

/// Tracks which partition Heimdall is writing and how far along it is, by reading
/// the strings FlashAction.cpp emits:
///   `Uploading SUPER`  …  `0%` `45%` `100%`  …  `SUPER upload successful`
struct FlashProgressParser {
    private(set) var currentPartition: String?
    private(set) var currentPercent: Int = 0
    private(set) var completedPartitions: [String] = []
    private(set) var errors: [String] = []

    private static let uploadingPrefix = "Uploading "
    private static let successSuffix = " upload successful"

    mutating func consume(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix(FlashProgressParser.uploadingPrefix) {
            currentPartition = String(trimmed.dropFirst(FlashProgressParser.uploadingPrefix.count))
            currentPercent = 0
            return
        }

        if trimmed.hasSuffix(FlashProgressParser.successSuffix) {
            let name = String(trimmed.dropLast(FlashProgressParser.successSuffix.count))
            if !completedPartitions.contains(name) {
                completedPartitions.append(name)
            }
            currentPercent = 100
            return
        }

        if trimmed.hasPrefix("ERROR:") {
            errors.append(trimmed)
            return
        }

        if let percent = FlashProgressParser.trailingPercent(in: trimmed) {
            currentPercent = percent
        }
    }

    /// Reads the in-flight line so the bar moves between completed lines.
    mutating func consume(partialLine: String) {
        if let percent = FlashProgressParser.trailingPercent(in: partialLine) {
            currentPercent = percent
        }
    }

    /// Pulls the number out of a string ending in `NN%`.
    static func trailingPercent(in text: String) -> Int? {
        guard text.hasSuffix("%") else { return nil }
        var digits = ""
        for character in text.dropLast().reversed() {
            guard character.isNumber else { break }
            digits.insert(character, at: digits.startIndex)
        }
        guard let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }
}

/// Filters the underlying CLI's banner out of the displayed log.
///
/// The flash engine prints its name, version and a copyright block on every run.
/// Valkyrie presents its own interface, so those lines are dropped from the log —
/// progress parsing still sees the complete stream, only the display is filtered.
enum EngineOutputFilter {
    private static let suppressedPrefixes = [
        "Heimdall ",
        "Copyright (c)",
        "This software is provided free of charge",
        "libusb is licensed under",
        "https://",
        "    https://",
    ]

    static func isDisplayable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return !suppressedPrefixes.contains { trimmed.hasPrefix($0) }
    }
}
