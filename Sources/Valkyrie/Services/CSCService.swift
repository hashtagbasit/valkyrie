import Foundation

/// One sales code available in the device's multi-CSC firmware.
struct CSCEntry: Identifiable, Hashable {
    let code: String
    var country: String?
    var countryISO: String?
    var region: String?
    var version: String?

    var id: String { code }

    /// Capability hints for a sales code.
    ///
    /// Samsung encrypts `cscfeature.xml` on current builds, so these cannot be read from
    /// the device. They are inferred from the region the device itself reports, plus a
    /// small override list for codes that are widely reported to differ. Treat them as a
    /// guide, not a guarantee — which is why the UI labels them as indications.
    var supportsCallRecording: Bool {
        if CSCEntry.recordingCodes.contains(code) { return true }
        if CSCEntry.noRecordingCodes.contains(code) { return false }
        // Recording is generally permitted outside Europe, North America and Oceania.
        return ["MEA", "SWA", "SEA", "CIS", "CHN"].contains(region ?? "")
    }

    var supportsSamsungPay: Bool {
        return ["EUR", "NAM", "SEA", "SWA", "CIS"].contains(region ?? "")
    }

    static let recordingCodes: Set<String> = [
        "INS", "INU", "KSA", "MID", "PAK", "PKD", "BNG", "THL",
        "XME", "XSP", "SIN", "EGY", "TUN", "AFG", "ACR", "LYS",
    ]

    static let noRecordingCodes: Set<String> = [
        "EUX", "EUY", "BTU", "DBT", "XEF", "ITV", "PHE", "XEO",
        "CPW", "SEK", "SFR", "PRT", "XSA", "XNZ", "VAU", "TPA",
    ]

    var badges: [(symbol: String, help: String)] {
        var result: [(String, String)] = []
        if supportsCallRecording { result.append(("🎙️", "Native call recording usually available")) }
        if supportsSamsungPay { result.append(("💳", "Samsung Wallet / Pay usually available")) }
        return result
    }

    var summary: String {
        let parts = [country, region].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? code : parts.joined(separator: " · ")
    }
}

enum CSCError: LocalizedError {
    case noDevice
    case adbMissing
    case noDiagnosticPort
    case portOpenFailed(String)
    case commandRejected(String)
    case writeIgnored(requested: String, stillReporting: String)
    case activationRefused

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No phone with USB debugging available. Connect it booted into Android with USB debugging on."
        case .adbMissing:
            return "adb isn't installed — `brew install --cask android-platform-tools`."
        case .noDiagnosticPort:
            return "No diagnostic serial port found. On the phone, dial *#0808# and select \"DM + ACM + ADB\", then reconnect."
        case .portOpenFailed(let detail):
            return "Couldn't open the diagnostic port: \(detail)"
        case .commandRejected(let response):
            return "The device rejected the command. It replied: \(response)"
        case .activationRefused:
            return "The modem refused to unlock (AT+ACTIVATE returned nothing), so nothing was written.\n\nOn the phone: Developer options → turn on \"3GPP AT commands\", set Default USB configuration to \"Transferring files\", keep the screen on and unlocked, and leave Auto Blocker off."
        case .writeIgnored(let requested, let still):
            return "The modem accepted the change to \(requested) but still reports \(still), so nothing was applied and the phone was not rebooted.\n\nCurrent Samsung firmware appears to require an authorisation step this app can't perform. Use the on-device method instead: dial *#272*<your IMEI># and pick the code there."
        }
    }
}

/// Reads and changes the device's CSC (sales code).
///
/// Multi-CSC firmware ships every sales code it supports on the device itself, under
/// `/optics/configs/carriers/single`, each with a `customer.xml` describing its country
/// and region. Reading those is far more accurate than any curated database, because it
/// describes this exact firmware rather than what a code means in general.
///
/// Changing the code goes over the modem's AT interface, which the phone exposes once
/// diagnostic mode is enabled from the dialer. No root, and nothing touches Knox.
enum CSCService {
    static let carriersPath = "/optics/configs/carriers/single"

    private static func adb() throws -> String {
        guard let path = DeviceIdentity.locateADB() else { throw CSCError.adbMissing }
        return path
    }

    private static func shell(_ command: String) async throws -> String {
        let result = try await CommandRunner().run(
            executable: try adb(), arguments: ["shell", command]
        )
        let text = result.output.replacingOccurrences(of: "\r", with: "")
        if text.contains("no devices") || text.contains("device not found") {
            throw CSCError.noDevice
        }
        return text
    }

    static func currentCode() async throws -> (code: String, country: String) {
        let code = try await shell("getprop ro.csc.sales_code")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let country = try await shell("getprop ro.csc.country_code")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw CSCError.noDevice }
        return (code, country)
    }

    /// Every sales code this firmware carries. Only these can be switched to — a code
    /// that isn't present would have to be flashed in.
    static func availableCodes() async throws -> [String] {
        let listing = try await shell("ls \(carriersPath) 2>/dev/null")
        return listing
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count == 3 && $0.uppercased() == $0 }
            .sorted()
    }

    /// Pulls country and region for one code out of its own `customer.xml`.
    static func details(for code: String) async throws -> CSCEntry {
        var entry = CSCEntry(code: code)
        let customer = try await shell(
            "cat \(carriersPath)/\(code)/conf/customer.xml 2>/dev/null | head -c 900"
        )
        entry.country = value(of: "Country", in: customer)
        entry.countryISO = value(of: "CountryISO", in: customer)
        entry.region = value(of: "Region", in: customer)

        let info = try await shell("cat \(carriersPath)/\(code)/conf/omc.info 2>/dev/null | head -c 400")
        entry.version = value(of: "version", in: info)
        return entry
    }

    /// Country and region for every code, in a single shell round-trip.
    ///
    /// Reading them one at a time would mean 128 adb invocations for a 64-code firmware,
    /// which takes long enough to feel broken.
    static func allEntries() async throws -> [CSCEntry] {
        let script = """
        for c in $(ls \(carriersPath) 2>/dev/null); do         printf "@@%s|" "$c";         head -c 700 \(carriersPath)/$c/conf/customer.xml 2>/dev/null | tr -d "\\n" |         grep -oE "<Country>[^<]*|<CountryISO>[^<]*|<Region>[^<]*" | sed "s/<[A-Za-z]*>//" | tr "\\n" "|";         echo; done
        """
        let output = try await shell(script)

        var entries: [CSCEntry] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("@@") else { continue }
            let fields = line.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let code = fields.first, code.count == 3 else { continue }
            var entry = CSCEntry(code: code)
            if fields.count > 1, !fields[1].isEmpty { entry.country = unescape(fields[1]) }
            if fields.count > 2, !fields[2].isEmpty { entry.countryISO = fields[2] }
            if fields.count > 3, !fields[3].isEmpty { entry.region = fields[3] }
            entries.append(entry)
        }
        return entries.sorted { $0.code < $1.code }
    }

    private static func unescape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else {
            return nil
        }
        let text = String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Diagnostic port

    /// Serial ports the phone exposes once diagnostic mode is on.
    static func diagnosticPorts() -> [String] {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return devices
            .filter { $0.hasPrefix("cu.usbmodem") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    /// Asks the modem which sales code it is running.
    ///
    /// `AT+PRECONFG=1,0` answers `+PRECONFG:1,<CODE>`. This is a read, so it doubles as a
    /// safe way to confirm the port really is the modem before anything is written — and
    /// as an independent check afterwards, since the Android property and the modem's own
    /// view can disagree until a reboot completes.
    static func readFromModem(port: String) throws -> String? {
        let serial = SerialPort()
        try serial.open(path: port)
        defer { serial.close() }

        try serial.write("AT+PRECONFG=1,0\r\n")
        let reply = serial.read(for: 4)
        guard let range = reply.range(of: "+PRECONFG:1,") else { return nil }
        let tail = reply[range.upperBound...]
        let code = tail.prefix { $0.isLetter || $0.isNumber }
        return code.isEmpty ? nil : String(code)
    }

    /// Applies a new sales code over the modem's AT interface.
    ///
    /// Verified working on a Galaxy Z Fold6 (Android 16) with no data loss. The order
    /// matters and every step earns its place:
    ///
    ///   AT+DUMPCTRL=1,0    without this, SWATD does nothing
    ///   AT+SWATD=0         switch the port into DDEXE mode
    ///   AT+ACTIVATE=0,0,0  unlocks the proprietary set — MUST answer +ACTIVATE:0,OK
    ///   AT+SWATD=1         back to ATD
    ///   AT+PRECONFG=2,XXX  the actual write
    ///   AT+PRECONFG=1,0    read back and confirm before rebooting
    ///
    /// The unlock is the whole game: without it the modem answers `OK` to the write and
    /// silently discards it, which looks exactly like success. So the write is refused
    /// unless ACTIVATE confirms. `AT+CFUN=1,1` answers `+CFUN=1,1:NA` and does not
    /// restart the phone — the caller reboots over adb instead.
    static func apply(code: String, port: String, log: @escaping (String) -> Void) throws {
        let serial = SerialPort()
        try serial.open(path: port)
        defer { serial.close() }

        func send(_ command: String, wait: TimeInterval, expect: String? = nil) -> String {
            serial.drain()
            log("> \(command)")
            try? serial.write(command + "\r")
            let reply = serial.read(for: wait, until: expect)
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            log(reply.isEmpty ? "< (no reply)" : "< \(reply)")
            return reply
        }

        let hello = send("AT", wait: 4)
        guard hello.uppercased().contains("OK") else {
            throw CSCError.commandRejected(hello.isEmpty ? "nothing" : hello)
        }

        _ = send("AT+DUMPCTRL=1,0", wait: 8)
        _ = send("AT+SWATD=0", wait: 6)

        let activate = send("AT+ACTIVATE=0,0,0", wait: 45, expect: "+ACTIVATE")
        guard activate.contains("+ACTIVATE") else {
            throw CSCError.activationRefused
        }

        _ = send("AT+SWATD=1", wait: 6)

        let written = send("AT+PRECONFG=2,\(code)", wait: 15)
        guard !written.uppercased().contains("ERROR") else {
            throw CSCError.commandRejected(written)
        }

        Thread.sleep(forTimeInterval: 3)
        let readback = send("AT+PRECONFG=1,0", wait: 12, expect: "+PRECONFG")
        let applied = readback.range(of: "+PRECONFG:1,").map { range -> String in
            String(readback[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
        }

        guard applied?.uppercased() == code.uppercased() else {
            throw CSCError.writeIgnored(requested: code, stillReporting: applied ?? "unknown")
        }

        log("Modem confirms \(code). Restarting the phone to apply it.")
    }
}

/// A minimal blocking serial port, enough for AT command exchanges.
final class SerialPort {
    private var descriptor: Int32 = -1

    func open(path: String) throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw CSCError.portOpenFailed("\(path) (errno \(errno))")
        }

        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            Darwin.close(fd)
            throw CSCError.portOpenFailed("couldn't read port settings")
        }
        cfmakeraw(&settings)
        cfsetispeed(&settings, speed_t(115200))
        cfsetospeed(&settings, speed_t(115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            Darwin.close(fd)
            throw CSCError.portOpenFailed("couldn't configure the port")
        }
        descriptor = fd
    }

    func write(_ text: String) throws {
        guard descriptor >= 0 else { throw CSCError.portOpenFailed("port is closed") }
        let bytes = [UInt8](text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Discards anything still sitting in the buffer.
    ///
    /// This modem answers slowly and lags a command behind, so a stale reply left in the
    /// buffer will be read as the *next* command's response. That cost hours of false
    /// positives — an old "+ACTIVATE:0,OK" read as a fresh success.
    func drain() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<15 {
            _ = Darwin.read(descriptor, &buffer, buffer.count)
            usleep(30_000)
        }
    }

    /// Reads until `until` appears, or a terminator, or the window expires.
    func read(for duration: TimeInterval, until marker: String? = nil) -> String {
        guard descriptor >= 0 else { return "" }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                collected.append(contentsOf: buffer[0..<count])
                let text = String(decoding: collected, as: UTF8.self)
                let done = marker.map { text.contains($0) } ?? (text.contains("OK") || text.contains("ERROR"))
                if done {
                    // Let the tail of the reply land before returning.
                    usleep(600_000)
                    let extra = Darwin.read(descriptor, &buffer, buffer.count)
                    if extra > 0 { collected.append(contentsOf: buffer[0..<extra]) }
                    break
                }
            } else {
                usleep(80_000)
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}
