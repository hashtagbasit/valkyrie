import SwiftUI

struct ToolsView: View {
    @EnvironmentObject private var monitor: DeviceMonitor
    @EnvironmentObject private var flashController: FlashController
    @StateObject private var tools = ToolsModel()
    @StateObject private var password = Local("")
    @StateObject private var authError = Local<String?>(nil)
    @StateObject private var isChecking = Local(false)

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                pitCard
                if let pit = tools.pit {
                    pitTableCard(pit)
                }
                deviceActionsCard
                if let info = tools.deviceInfo {
                    Card(title: "Device info", subtitle: "USB descriptors reported by the device") {
                        ScrollView {
                            Text(info)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
                usbCard
                housekeepingCard
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $tools.needsAuthentication) {
            AuthSheet(
                password: password.binding,
                errorText: authError.value,
                isChecking: isChecking.value,
                onCancel: {
                    tools.needsAuthentication = false
                    password.value = ""
                    authError.value = nil
                },
                onConfirm: {
                    Task {
                        authError.value = nil
                        isChecking.value = true
                        let entered = password.value
                        let ok = await tools.authenticate(password: entered)
                        isChecking.value = false
                        if ok {
                            password.value = ""
                        } else {
                            authError.value = "That password wasn't accepted."
                        }
                    }
                }
            )
            .onAppear { authError.value = nil }
        }
    }

    private var pitCard: some View {
        Card(
            title: "Partition table",
            subtitle: tools.pitSource.map { "Loaded from \($0)" } ?? "Inspect a PIT from a file or straight off the phone"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        tools.openPitFile()
                    } label: {
                        Label("Open .pit File…", systemImage: "doc")
                    }
                    .controlSize(.small)

                    Button {
                        Task { await tools.readFromDevice() }
                    } label: {
                        if tools.isReading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Read From Device", systemImage: "arrow.down.doc")
                        }
                    }
                    .controlSize(.small)
                    .disabled(!monitor.isConnected || tools.isReading)

                    if tools.pit != nil {
                        Button("Clear") { tools.clear() }
                            .controlSize(.small)
                    }
                    Spacer()
                }

                Text("Reading the PIT writes nothing to the phone — it's the safest way to confirm the USB path works before a real flash.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if let message = tools.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(tools.messageIsError ? Theme.danger : Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pitTableCard(_ pit: PitData) -> some View {
        Card(
            title: "Entries",
            subtitle: "\(pit.entries.count) partitions · \(pit.flashableEntries.count) flashable"
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("ID").frame(width: 34, alignment: .leading)
                    Text("Partition").frame(width: 150, alignment: .leading)
                    Text("Flash file").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Type").frame(width: 70, alignment: .leading)
                    Text("Blocks").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(pit.entries) { entry in
                            HStack(spacing: 8) {
                                Text("\(entry.identifier)")
                                    .frame(width: 34, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(entry.partitionName)
                                    .frame(width: 150, alignment: .leading)
                                    .fontWeight(entry.isFlashable ? .medium : .regular)
                                Text(entry.isFlashable ? entry.flashFilename : "—")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(entry.isFlashable ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.deviceTypeLabel)
                                    .frame(width: 70, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text("\(entry.blockCount)")
                                    .frame(width: 90, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(
                                entry.isFlashable
                                    ? Theme.accent.opacity(0.05)
                                    : Color.clear
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private var deviceActionsCard: some View {
        Card(title: "Device actions", subtitle: "Engine commands that talk to the bootloader") {
            HStack(spacing: 8) {
                Button {
                    Task { await tools.readDeviceInfo() }
                } label: {
                    Label("Device Info", systemImage: "info.circle")
                }
                .controlSize(.small)
                .disabled(!monitor.isConnected || tools.isRunningAction)

                Button {
                    Task { await tools.closePCScreen() }
                } label: {
                    Label("Clear \"Connect to PC\" Screen", systemImage: "display.trianglebadge.exclamationmark")
                }
                .controlSize(.small)
                .disabled(!monitor.isConnected || tools.isRunningAction)

                if tools.isRunningAction {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private var usbCard: some View {
        Card(
            title: "USB devices",
            subtitle: "\(monitor.allDevices.count) attached · read through IOKit, no privileges needed"
        ) {
            if monitor.samsungDevices.isEmpty {
                Text("No Samsung device attached.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(monitor.samsungDevices) { device in
                        HStack(spacing: 8) {
                            Image(systemName: device.isDownloadMode ? "bolt.circle.fill" : "iphone")
                                .foregroundStyle(device.isDownloadMode ? Theme.success : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 11.5))
                                if let serial = device.serial, !serial.isEmpty {
                                    Text(serial)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(device.identifierString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if device.isDownloadMode {
                                StatusPill(text: "download mode", color: Theme.success)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .cardBackground()
                    }
                }
            }
        }
    }

    private var housekeepingCard: some View {
        Card(title: "Housekeeping", subtitle: "Unpacked images are roughly the size of the firmware again") {
            HStack {
                if let package = flashController.package {
                    let size = FirmwareExtractor.workDirectorySize(for: package)
                    Text(size > 0
                         ? "Unpacked images: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
                         : "Nothing unpacked for this firmware folder.")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Delete Unpacked Images", role: .destructive) {
                        try? FirmwareExtractor.cleanUp(package: package)
                    }
                    .controlSize(.small)
                    .disabled(size == 0)
                } else {
                    Text("Load a firmware folder on the Flash tab first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}
