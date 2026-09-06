import Foundation
import CryptoKit

/// Samsung's firmware servers authenticate with a whitebox construction: the server
/// hands out a 16-character nonce, and the client must return a signature derived from
/// it using a large lookup table shipped inside Samsung's own software.
///
/// The table is not redistributed with Valkyrie. It's fetched once on first use and
/// cached in Application Support, so the repository stays free of Samsung binaries.
enum AuthParamStore {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/zacharee/SamloaderKotlin/master/common/src/commonMain/composeResources/files/auth_param.dat")!

    /// The table is a fixed size; anything else means a truncated or wrong download.
    static let expectedByteCount = 820_792

    static var cacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Valkyrie", isDirectory: true)
        return support.appendingPathComponent("auth_param.dat")
    }

    static var isCached: Bool {
        FileManager.default.fileExists(atPath: cacheURL.path)
    }

    static func load() async throws -> [UInt8] {
        if let cached = try? Data(contentsOf: cacheURL), cached.count == expectedByteCount {
            return [UInt8](cached)
        }
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FusError.authTableUnavailable("HTTP \(http.statusCode)")
        }
        guard data.count == expectedByteCount else {
            throw FusError.authTableUnavailable("unexpected size \(data.count)")
        }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL)
        return [UInt8](data)
    }
}

enum FusCrypto {
    private static let shiftIndices = [0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11]

    /// Transforms a 16-byte block through the lookup table to produce the request
    /// signature. Nine rounds, each mixing the block through selector and substitution
    /// tables addressed by offsets declared in the table's own 56-byte header.
    static func authenticateBlock(_ input: [UInt8], table: [UInt8]) -> [UInt8] {
        func le32(_ index: Int) -> Int {
            let o = index * 4
            return Int(UInt32(table[o]) | UInt32(table[o + 1]) << 8
                       | UInt32(table[o + 2]) << 16 | UInt32(table[o + 3]) << 24)
        }
        // Header layout: magic, alignment, then (offset, size) pairs per block.
        let block1Size = le32(3)
        let block2Size = le32(5)
        let block3Size = le32(11)
        let headerOffset = 56

        func byte(_ position: Int) -> Int { Int(table[position + headerOffset]) }

        var temp = [Int](repeating: 0, count: 320)
        for index in 0..<16 { temp[index] = Int(input[index]) }
        var mixed = [Int](repeating: 0, count: 64)
        var output = [UInt8](repeating: 0, count: 16)

        for round in 0..<9 {
            let srcStart = round * 32
            let nextStart = (round + 1) * 32
            let blockIdBase = round * 16
            let srcMid = srcStart + 16

            for index in 0..<16 {
                temp[srcStart + 16 + index] = temp[srcStart + shiftIndices[index]]
            }

            for column in 0..<4 {
                let c4 = column << 2
                let c16 = column << 4
                let blockIdRow = blockIdBase + c4
                let subBase = block1Size + block2Size + block3Size + 6144 * (column + (round << 2))

                for k in 0..<4 {
                    let value = temp[srcMid + c4 + k]
                    let blockId = blockIdRow + k
                    let srcBase = (blockId << 12) + (value << 4)
                    let selectorBase = block1Size + block2Size + (blockId << 5)
                    let outStart = c16 + (k << 2)

                    for outIndex in 0..<4 {
                        var accumulator = 0
                        let selBase = outIndex << 3
                        for bit in 0..<8 {
                            let selector = byte(selectorBase + selBase + bit)
                            let sourceIndex = (selector >> 3) & 0x1F
                            let bitPosition = 7 - (selector & 0x7)
                            let sourceByte = sourceIndex < 16 ? byte(srcBase + sourceIndex) : 0
                            accumulator |= ((sourceByte >> bitPosition) & 1) << (7 - bit)
                        }
                        mixed[outStart + outIndex] = accumulator & 0xFF
                    }
                }

                for k in 0..<4 {
                    let a1 = mixed[c16 + k], a2 = mixed[c16 + k + 4]
                    let a3 = mixed[c16 + k + 8], a4 = mixed[c16 + k + 12]
                    let base = subBase + 1536 * k
                    let hi1 = ((a1 & 0xF0) | (a2 >> 4)) & 0xFF
                    let lo1 = (((a1 & 0x0F) << 4) | (a2 & 0x0F)) & 0xFF
                    let v6 = ((16 * byte(base + hi1)) ^ byte(base + 256 + lo1)) & 0xFF
                    let hi2 = ((a3 & 0xF0) | (a4 >> 4)) & 0xFF
                    let lo2 = (((a3 & 0x0F) << 4) | (a4 & 0x0F)) & 0xFF
                    let v7 = ((16 * byte(base + 512 + hi2)) ^ byte(base + 768 + lo2)) & 0xFF
                    let hi3 = ((v6 & 0xF0) | (v7 >> 4)) & 0xFF
                    let lo3 = (((v6 & 0x0F) << 4) | (v7 & 0x0F)) & 0xFF
                    temp[nextStart + c4 + k] =
                        ((16 * byte(base + 1024 + hi3)) ^ byte(base + 1280 + lo3)) & 0xFF
                }
            }
        }

        for index in 0..<16 {
            let position = block1Size + (index << 8) + temp[shiftIndices[index] + 288]
            output[index] = UInt8(byte(position))
        }
        return output
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Samsung's "logic check": index into the firmware string with the low nibble of
    /// each nonce character. Used both to prove nonce possession and to derive the
    /// firmware decryption key.
    static func logicCheck(_ input: String, nonce: String) -> String {
        guard input.count >= 16 else { return "" }
        let characters = Array(input)
        return String(nonce.unicodeScalars.map { characters[Int($0.value) & 0xF] })
    }

    /// Samsung publishes three-part version strings but expects four in requests.
    static func normalizeVersion(_ raw: String) -> String {
        var parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 { parts.append(parts[0]) }
        if parts.count >= 3, parts[2].isEmpty { parts[2] = parts[0] }
        return parts.joined(separator: "/")
    }

    static func md5(_ text: String) -> [UInt8] {
        return Array(Insecure.MD5.hash(data: Data(text.utf8)))
    }
}
