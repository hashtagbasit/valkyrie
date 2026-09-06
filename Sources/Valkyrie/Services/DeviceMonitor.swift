import Foundation
import IOKit

struct USBDevice: Identifiable, Hashable {
    let vendorID: Int
    let productID: Int
    let name: String
    let serial: String?

    var id: String { "\(vendorID):\(productID):\(serial ?? name)" }

    var isSamsung: Bool { vendorID == USBScanner.samsungVendorID }
    var isDownloadMode: Bool { isSamsung && USBScanner.downloadModeProductIDs.contains(productID) }

    var identifierString: String {
        return String(format: "%04x:%04x", vendorID, productID)
    }
}

/// Reads the USB device tree through IOKit. This needs no privileges, which is why
/// Valkyrie can show live connection state without ever asking for a password —
/// only the actual flash needs root.
enum USBScanner {
    static let samsungVendorID = 0x04E8

    /// Product IDs Samsung's Loke/Odin bootloader presents in download mode.
    /// Deliberately excludes 0x6860, which is a normally-booted phone in MTP mode.
    static let downloadModeProductIDs: Set<Int> = [0x685D, 0x6601, 0x68C3, 0x685E]

    static func scan() -> [USBDevice] {
        // macOS 10.11+ publishes IOUSBHostDevice; fall back to the older class name
        // so this keeps working on anything still exposing IOUSBDevice.
        var devices = scan(matchingClass: "IOUSBHostDevice")
        if devices.isEmpty {
            devices = scan(matchingClass: "IOUSBDevice")
        }
        return devices
    }

    private static func scan(matchingClass className: String) -> [USBDevice] {
        guard let matching = IOServiceMatching(className) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [USBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let vendor = intProperty(service, "idVendor"),
                  let product = intProperty(service, "idProduct") else { continue }
            result.append(USBDevice(
                vendorID: vendor,
                productID: product,
                name: stringProperty(service, "USB Product Name") ?? "USB device",
                serial: stringProperty(service, "USB Serial Number")
            ))
        }
        return result
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (raw.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }
}

/// Polls the USB tree and publishes what's attached. Polling rather than IOKit
/// notifications keeps this to one code path and a scan costs only a few ms.
@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var samsungDevices: [USBDevice] = []
    @Published private(set) var downloadModeDevice: USBDevice?
    @Published private(set) var allDevices: [USBDevice] = []

    private var timer: Timer?

    var isConnected: Bool { downloadModeDevice != nil }

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let devices = USBScanner.scan()
        guard devices != allDevices else { return }
        allDevices = devices
        samsungDevices = devices.filter { $0.isSamsung }
        downloadModeDevice = devices.first { $0.isDownloadMode }
    }
}
