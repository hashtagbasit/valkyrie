import Foundation

@MainActor
final class CSCModel: ObservableObject {
    @Published private(set) var currentCode: String?
    @Published private(set) var currentCountry: String?
    @Published private(set) var modemCode: String?
    @Published private(set) var entries: [CSCEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var ports: [String] = []
    @Published private(set) var log: [LogLine] = []
    @Published var selectedPort: String?
    @Published var selectedCode: String?
    @Published var search = ""

    var filtered: [CSCEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.code.lowercased().contains(query)
                || ($0.country ?? "").lowercased().contains(query)
                || ($0.region ?? "").lowercased().contains(query)
        }
    }

    var canApply: Bool {
        return blockedReason == nil && !isApplying
    }

    /// Why the apply button is unavailable, so the UI never greys out silently.
    var blockedReason: String? {
        if isApplying { return "Applying…" }
        guard selectedCode != nil else { return "Pick a CSC from the list first." }
        guard selectedPort != nil else { return "No diagnostic port — connect the phone with USB debugging on." }
        if selectedCode == currentCode { return "That CSC is already active." }
        return nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        refreshPorts()
        readModemCode()
        do {
            let current = try await CSCService.currentCode()
            currentCode = current.code
            currentCountry = current.country
            entries = try await CSCService.allEntries()
            if entries.isEmpty {
                errorMessage = "No sales codes found on the device. This firmware may not be multi-CSC."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Independent confirmation straight from the modem.
    func readModemCode() {
        guard let port = selectedPort else { modemCode = nil; return }
        modemCode = try? CSCService.readFromModem(port: port)
    }

    func refreshPorts() {
        ports = CSCService.diagnosticPorts()
        if selectedPort == nil || !(ports.contains(selectedPort ?? "")) {
            selectedPort = ports.first
        }
    }

    func apply() async {
        guard let code = selectedCode, let port = selectedPort, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        append("Applying \(code) via \(port)", kind: .command)
        do {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try CSCService.apply(code: code, port: port) { line in
                    Task { @MainActor in self?.append(line, kind: .info) }
                }
            }.value
            await rebootAndVerify(expecting: code)
            readModemCode()
            CompletionAlert.signal(success: true)
        } catch {
            append(error.localizedDescription, kind: .error)
            errorMessage = error.localizedDescription
            CompletionAlert.signal(success: false)
        }
    }

    /// Restarts the phone and confirms the new code actually took.
    ///
    /// The modem stages the change but does not apply it, and `AT+CFUN=1,1` answers
    /// `+CFUN=1,1:NA` without restarting anything — so the reboot has to come from adb.
    /// If that isn't possible the user is told to do it by hand rather than being left
    /// with a staged change and a success message.
    private func rebootAndVerify(expecting code: String) async {
        guard let adb = DeviceIdentity.locateADB() else {
            append("Change is staged, but adb isn't available to restart the phone. Reboot it yourself — \(code) applies on boot.", kind: .error)
            return
        }

        append("Restarting the phone to apply \(code)…", kind: .info)
        let result = try? await CommandRunner().run(executable: adb, arguments: ["reboot"])
        guard result?.succeeded == true else {
            append("Couldn't restart the phone automatically. Reboot it yourself — \(code) is staged and applies on boot.", kind: .error)
            return
        }

        // Wait for it to come back, then read the code Android reports.
        for attempt in 1...30 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let booted = try? await CommandRunner().run(
                executable: adb, arguments: ["shell", "getprop", "sys.boot_completed"]
            )
            guard booted?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
                if attempt % 4 == 0 { append("still restarting…", kind: .info) }
                continue
            }
            let applied = try? await CommandRunner().run(
                executable: adb, arguments: ["shell", "getprop", "ro.csc.sales_code"]
            )
            let value = applied?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.uppercased() == code.uppercased() {
                currentCode = value
                append("Confirmed — the phone is now on \(value), user data intact.", kind: .success)
            } else {
                append("Phone restarted but reports \(value.isEmpty ? "nothing" : value) rather than \(code).", kind: .error)
            }
            await refresh()
            return
        }
        append("The phone didn't come back within a few minutes. Check it, then hit refresh.", kind: .error)
    }

    private func append(_ text: String, kind: LogLine.Kind) {
        log.append(LogLine(text: text, kind: kind))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log = [] }
}
