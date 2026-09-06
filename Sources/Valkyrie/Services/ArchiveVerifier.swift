import Foundation
import CryptoKit

enum ArchiveVerificationError: LocalizedError {
    case noChecksum(String)
    case mismatch(file: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .noChecksum(let file):
            return "\(file) has no appended checksum to verify against."
        case .mismatch(let file, let expected, let actual):
            return "\(file) is corrupt — its checksum should be \(expected.prefix(12))… but the file computes to \(actual.prefix(12))…. Download the firmware again rather than flashing it."
        }
    }
}

/// Verifies the MD5 Samsung appends to every `.tar.md5`.
///
/// The file is an ordinary tar with `md5sum` output — `<hash>␠␠<name>\n` — glued onto the
/// end, and the hash covers everything before that line. Odin checks this; skipping it
/// means a tarball corrupted in transit reaches the phone unnoticed, which is the kind of
/// silent failure that bricks a device.
enum ArchiveVerifier {
    private static let chunkSize = 8 * 1024 * 1024

    struct Expectation {
        let hash: String
        /// Byte length of the tar content the hash covers.
        let contentLength: Int64
    }

    /// Locates the appended checksum line and the offset where tar content ends.
    ///
    /// The line is found by pattern rather than by splitting on newlines: tar pads with
    /// NUL bytes, so there is usually no newline separating the padding from the checksum.
    static func expectation(for url: URL) throws -> Expectation? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int64(try handle.seekToEnd())
        guard size > 40 else { return nil }

        let tailLength = Int(min(size, 1024))
        try handle.seek(toOffset: UInt64(size - Int64(tailLength)))
        let tail = [UInt8](handle.readData(ofLength: tailLength))

        func isHex(_ byte: UInt8) -> Bool {
            return (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
                || (byte >= 0x41 && byte <= 0x46)
        }

        // Take the last "<32 hex><space><space>" in the tail.
        var match: Int?
        var index = 0
        while index + 34 <= tail.count {
            if tail[index + 32] == 0x20, tail[index + 33] == 0x20,
               (0..<32).allSatisfy({ isHex(tail[index + $0]) }) {
                match = index
            }
            index += 1
        }
        guard let start = match else { return nil }

        let hash = String(decoding: tail[start..<(start + 32)], as: UTF8.self).lowercased()
        return Expectation(hash: hash, contentLength: size - Int64(tailLength) + Int64(start))
    }

    /// Streams the file and compares against the appended checksum.
    static func verify(
        url: URL,
        isCancelled: @escaping () -> Bool,
        progress: @escaping (Int64, Int64) -> Void
    ) throws -> Bool {
        guard let expectation = try expectation(for: url) else {
            throw ArchiveVerificationError.noChecksum(url.lastPathComponent)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)

        var hasher = Insecure.MD5()
        var remaining = expectation.contentLength
        let total = expectation.contentLength

        while remaining > 0 {
            if isCancelled() { return false }
            let wanted = Int(min(Int64(chunkSize), remaining))
            let chunk = handle.readData(ofLength: wanted)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
            progress(total - remaining, total)
        }

        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectation.hash else {
            throw ArchiveVerificationError.mismatch(
                file: url.lastPathComponent, expected: expectation.hash, actual: actual
            )
        }
        return true
    }
}
