import Foundation
import CommonCrypto

enum FusError: LocalizedError {
    case authTableUnavailable(String)
    case noNonce
    case server(status: String)
    case malformedResponse
    case transport(String)
    case decryptionFailed(Int32)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case unpackFailed(String)

    var errorDescription: String? {
        switch self {
        case .authTableUnavailable(let detail):
            return "Couldn't fetch the authentication table (\(detail)). Check your connection and try again."
        case .noNonce:
            return "Samsung's server didn't issue a session nonce."
        case .server(let status):
            switch status {
            case "408": return "Samsung rejected the request as unauthorised — the session expired. Try again."
            case "401": return "Samsung rejected the authentication."
            default: return "Samsung's server returned status \(status)."
            }
        case .malformedResponse:
            return "Samsung returned a response this build couldn't read."
        case .transport(let detail):
            return "Network error: \(detail)"
        case .decryptionFailed(let code):
            return "Decryption failed (CommonCrypto status \(code))."
        case .sizeMismatch(let expected, let actual):
            return "Download is incomplete — expected \(expected) bytes but have \(actual)."
        case .checksumMismatch(let expected, let actual):
            return "The download is corrupt — Samsung's checksum is \(expected) but the file computes to \(actual). Delete it and download again rather than flashing it."
        case .unpackFailed(let detail):
            return "Couldn't unpack the archive: \(detail)"
        }
    }
}

/// Everything Samsung tells us about one firmware binary.
struct FusBinaryInfo {
    let fileName: String
    let modelPath: String
    let byteSize: Int64
    let crc: String
    let logicValueFactory: String
    let version: String
    let model: String
    let region: String

    var isEncrypted: Bool { fileName.hasSuffix(".enc4") || fileName.hasSuffix(".enc2") }
    /// The archive without its .zip suffix — used as the unpacked folder name.
    var folderName: String {
        var name = decryptedName
        if name.hasSuffix(".zip") { name.removeLast(4) }
        return name
    }

    var decryptedName: String {
        return fileName
            .replacingOccurrences(of: ".enc4", with: "")
            .replacingOccurrences(of: ".enc2", with: "")
    }

    var formattedSize: String {
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// `.enc4` files are AES-128-ECB, keyed by the MD5 of a logic check run over the
    /// version string with the server-supplied factory value as the nonce.
    var decryptionKey: [UInt8] {
        return FusCrypto.md5(FusCrypto.logicCheck(version, nonce: logicValueFactory))
    }
}

/// Talks to Samsung's firmware distribution service.
///
/// The flow is: request a nonce, sign it with the whitebox table, ask for binary
/// information, initialise the download, then stream the encrypted file and decrypt it.
actor FusClient {
    private var nonce = ""
    private var signature = ""
    private var sessionId = ""
    private var table: [UInt8] = []

    private let base = "https://neofussvr.sslcs.cdngc.net/"

    func prepare() async throws {
        if table.isEmpty {
            table = try await AuthParamStore.load()
        }
    }

    private var authorizationHeader: String {
        return "FUS nonce=\"\(nonce)\", signature=\"\(signature)\", nc=\"\", type=\"\", realm=\"\""
    }

    private var cookieHeader: String {
        return sessionId.isEmpty ? "" : "JSESSIONID=\(sessionId);SESSION=\(sessionId)"
    }

    func downloadHeaders() -> [String: String] {
        var headers = [
            "Authorization": authorizationHeader,
            "User-Agent": "SMART 2.0",
            "Cache-Control": "no-cache",
        ]
        if !cookieHeader.isEmpty { headers["Cookie"] = cookieHeader }
        return headers
    }

    func downloadURL(for info: FusBinaryInfo) -> URL {
        let path = info.modelPath + info.fileName
        return URL(string: "https://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file=\(path)")!
    }

    // MARK: - Requests

    private func post(_ path: String, body: String) async throws -> (headers: [String: String], text: String) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("SMART 2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        request.httpBody = Data(body.utf8)
        request.setValue("\(body.utf8.count)", forHTTPHeaderField: "Content-Length")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FusError.transport(error.localizedDescription)
        }

        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
        }

        // Every response may rotate the nonce; keep the session current.
        if let fresh = headers["nonce"], !fresh.isEmpty {
            adopt(nonce: fresh)
        }
        if let cookie = headers["set-cookie"] {
            adopt(cookie: cookie)
        }

        return (headers, String(decoding: data, as: UTF8.self))
    }

    private func adopt(nonce fresh: String) {
        nonce = fresh
        let block = [UInt8](fresh.prefix(16).utf8)
        guard block.count == 16, !table.isEmpty else { return }
        signature = FusCrypto.hexString(FusCrypto.authenticateBlock(block, table: table))
    }

    private func adopt(cookie raw: String) {
        for part in raw.split(separator: ",") {
            for piece in part.split(separator: ";") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("JSESSIONID=") || trimmed.hasPrefix("SESSION=") {
                    sessionId = trimmed
                        .replacingOccurrences(of: "JSESSIONID=", with: "")
                        .replacingOccurrences(of: "SESSION=", with: "")
                    return
                }
            }
        }
    }

    func generateNonce() async throws {
        try await prepare()
        nonce = ""
        signature = ""
        let result = try await post("NF_SmartDownloadGenerateNonce.do", body: "")
        guard !nonce.isEmpty, !signature.isEmpty else {
            _ = result
            throw FusError.noNonce
        }
    }

    func binaryInform(version rawVersion: String, model: String, region: String) async throws -> FusBinaryInfo {
        if nonce.isEmpty { try await generateNonce() }

        let version = FusCrypto.normalizeVersion(rawVersion)
        let check = FusCrypto.logicCheck(version, nonce: nonce)

        // A few regions need a plausible country and network attached to the request.
        var extras = ""
        switch region {
        case "EUX": extras = "<DEVICE_CC_CODE><Data>DE</Data></DEVICE_CC_CODE><MCC_NUM><Data>262</Data></MCC_NUM><MNC_NUM><Data>01</Data></MNC_NUM>"
        case "EUY": extras = "<DEVICE_CC_CODE><Data>RS</Data></DEVICE_CC_CODE><MCC_NUM><Data>220</Data></MCC_NUM><MNC_NUM><Data>01</Data></MNC_NUM>"
        default: extras = ""
        }

        let body = """
        <?xml version="1.0" encoding="UTF-8"?><FUSMsg><FUSHdr><ProtoVer>1.0</ProtoVer><SessionID>0</SessionID><MsgID>1</MsgID></FUSHdr><FUSBody><Put><CmdID>1</CmdID><REQUEST_TYPE><Data>2</Data></REQUEST_TYPE><BINARY_SW_VERSION><Data>\(version)</Data></BINARY_SW_VERSION><DEVICE_SN_NUMBER><Data></Data></DEVICE_SN_NUMBER><BINARY_LOCAL_CODE><Data>\(region)</Data></BINARY_LOCAL_CODE><BINARY_MODEL_NAME><Data>\(model)</Data></BINARY_MODEL_NAME><ACCESS_MODE><Data>1</Data></ACCESS_MODE><BINARY_NATURE><Data>1</Data></BINARY_NATURE><LOGIC_CHECK><Data>\(check)</Data></LOGIC_CHECK><CLIENT_LANGUAGE><Type>String</Type><Type>ISO 3166-1-alpha-3</Type><Data>1033</Data></CLIENT_LANGUAGE>\(extras)</Put><Get><CmdID>2</CmdID><BINARY_SW_VERSION/></Get></FUSBody></FUSMsg>
        """

        let result = try await post("NF_SmartDownloadBinaryInform.do", body: body)
        let status = FusXML.value(of: "Status", in: result.text) ?? "?"
        guard status == "S00" || status == "S01" else {
            throw FusError.server(status: status)
        }
        guard let fileName = FusXML.dataValue(of: "BINARY_NAME", in: result.text),
              let path = FusXML.dataValue(of: "MODEL_PATH", in: result.text),
              let sizeText = FusXML.dataValue(of: "BINARY_BYTE_SIZE", in: result.text),
              let size = Int64(sizeText) else {
            throw FusError.malformedResponse
        }

        return FusBinaryInfo(
            fileName: fileName,
            modelPath: path,
            byteSize: size,
            crc: FusXML.dataValue(of: "BINARY_CRC", in: result.text) ?? "",
            logicValueFactory: FusXML.dataValue(of: "LOGIC_VALUE_FACTORY", in: result.text) ?? "",
            version: version,
            model: model,
            region: region
        )
    }

    /// Samsung requires this before the CDN will serve the file.
    func binaryInit(info: FusBinaryInfo) async throws {
        // The init logic check runs over a fixed slice of the file name.
        let name = info.fileName
        guard name.count >= 25 else { throw FusError.malformedResponse }
        let start = name.index(name.endIndex, offsetBy: -25)
        let end = name.index(name.endIndex, offsetBy: -9)
        let check = FusCrypto.logicCheck(String(name[start..<end]), nonce: nonce)

        let body = """
        <?xml version="1.0" encoding="UTF-8"?><FUSMsg><FUSHdr><ProtoVer>1.0</ProtoVer><SessionID>0</SessionID><MsgID>1</MsgID></FUSHdr><FUSBody><Put><BINARY_NAME><Data>\(info.fileName)</Data></BINARY_NAME><BINARY_SW_VERSION><Data>\(info.version)</Data></BINARY_SW_VERSION><DEVICE_LOCAL_CODE><Data>\(info.region)</Data></DEVICE_LOCAL_CODE><LOGIC_CHECK><Data>\(check)</Data></LOGIC_CHECK></Put></FUSBody></FUSMsg>
        """

        let result = try await post("NF_SmartDownloadBinaryInitForMass.do", body: body)
        let status = FusXML.value(of: "Status", in: result.text) ?? "?"
        guard status == "S00" || status == "S01" else {
            throw FusError.server(status: status)
        }
    }
}

/// Minimal extraction for Samsung's flat response documents.
enum FusXML {
    static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Most fields are wrapped as `<TAG><Data>value</Data></TAG>`.
    static func dataValue(of tag: String, in xml: String) -> String? {
        guard let outer = value(of: tag, in: xml) else { return nil }
        if let inner = value(of: "Data", in: outer) { return inner }
        return outer.isEmpty ? nil : outer
    }
}

/// Streaming CRC-32 (the standard reflected polynomial, as used by zip and by
/// Samsung's `BINARY_CRC`).
struct Crc32 {
    private static let table: [UInt32] = {
        return (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var value = state
        for byte in bytes {
            value = Crc32.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        state = value
    }

    var checksum: UInt32 { state ^ 0xFFFF_FFFF }
}

/// AES-128-ECB decryption for `.enc4` firmware.
///
/// ECB has no chaining, so the file can be decrypted block-aligned chunk by chunk —
/// which is what makes streaming a 20GB archive practical without holding it in memory.
enum FirmwareDecryptor {
    static let chunkSize = 4 * 1024 * 1024

    /// Returns the CRC-32 of the *encrypted* input, computed in the same pass.
    /// Samsung supplies that checksum with the binary information, and verifying it
    /// this way costs nothing — the bytes are already being read.
    @discardableResult
    static func decrypt(
        source: URL,
        destination: URL,
        key: [UInt8],
        totalBytes: Int64,
        isCancelled: @escaping () -> Bool,
        progress: @escaping (Int64, Int64) -> Void
    ) throws -> UInt32 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        var processed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var crc = Crc32()

        while true {
            if isCancelled() { return crc.checksum }
            let chunk = input.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }

            chunk.withUnsafeBytes { crc.update($0) }

            var written = 0
            let status = chunk.withUnsafeBytes { raw -> CCCryptorStatus in
                return CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    key, key.count,
                    nil,
                    raw.baseAddress, chunk.count,
                    &buffer, buffer.count,
                    &written
                )
            }
            guard status == kCCSuccess else { throw FusError.decryptionFailed(status) }

            processed += Int64(chunk.count)
            var slice = Array(buffer[0..<written])

            // The final block carries PKCS#7 padding.
            if processed >= totalBytes, let pad = slice.last, pad >= 1, pad <= 16, slice.count >= Int(pad) {
                slice.removeLast(Int(pad))
            }
            output.write(Data(slice))
            progress(processed, totalBytes)
        }
        return crc.checksum
    }
}
