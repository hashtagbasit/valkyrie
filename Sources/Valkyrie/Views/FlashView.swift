import SwiftUI
import UniformTypeIdentifiers

struct FlashView: View {
    @EnvironmentObject private var controller: FlashController
    @EnvironmentObject private var monitor: DeviceMonitor

    @StateObject private var dropTargeted = Local(false)
    @StateObject private var showAuth = Local(false)
    @StateObject private var password = Local("")
    @StateObject private var authError = Local<String?>(nil)
    @StateObject private var isChecking = Local(false)
    @StateObject private var confirmWipe = Local(false)

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 14) {
                    firmwareCard
                    if controller.package != nil {
                        optionsCard
                        actionCard
                    }
                }
                .padding(Theme.gutter)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 520)

            VStack(spacing: 14) {
                progressCard
                planCard
                LogConsoleView(lines: controller.log, onClear: { controller.clearLog() }, onExport: { controller.exportLog() })
                if controller.log.isEmpty { Spacer(minLength: 0) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(Theme.gutter)
            .frame(minWidth: 480)
        }
        .sheet(isPresented: showAuth.binding) {
            AuthSheet(
                password: password.binding,
                errorText: authError.value,
                isChecking: isChecking.value,
                onCancel: {
                    showAuth.value = false
                    password.value = ""
                    authError.value = nil
                },
                onConfirm: { authenticateThenFlash() }
            )
        }
        .confirmationDialog(
            "This will erase your data",
            isPresented: confirmWipe.binding,
            titleVisibility: .visible
        ) {
            Button("Erase and flash", role: .destructive) { beginFlash() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("These selected partitions overwrite your data: \(controller.destructivePartitions.map { $0.partitionName }.joined(separator: ", ")).\n\nEverything on the phone in them will be gone. Untick them in the partition list to keep your data and still flash the firmware.")
        }
    }

    // MARK: - Firmware

    private var firmwareCard: some View {
        Card(
            title: "Firmware",
            subtitle: controller.package.map { $0.directory.lastPathComponent } ?? "Drop an unzipped firmware folder"
        ) {
            if let package = controller.package, !package.isEmpty {
                VStack(spacing: 8) {
                    ForEach(package.archives) { archive in
                        slotRow(archive)
                    }
                }
                HStack {
                    Button("Choose Another Folder…") { chooseFolder() }
                        .controlSize(.small)
                    Spacer()
                    if let build = package.buildVersion {
                        Text(build)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                dropZone
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(dropTargeted.value ? Theme.accent : .secondary)
            Text("Drop the unzipped firmware folder here")
                .font(.system(size: 12))
            Text("The folder holding BL / AP / CP / CSC .tar.md5 files")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Button("Choose Folder…") { chooseFolder() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(dropTargeted.value ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(
                    dropTargeted.value ? Theme.accent : Color.primary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: dropTargeted.binding) { providers in
            handleDrop(providers)
        }
    }

    private func slotRow(_ archive: FirmwareArchive) -> some View {
        let isOn = controller.selectedSlots.contains(archive.slot)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { enabled in toggleSlot(archive.slot, enabled: enabled) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(archive.slot.rawValue)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    if archive.slot.wipesUserData && isOn {
                        StatusPill(text: "wipes data", color: Theme.danger)
                    }
                }
                Text(archive.slot.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(archive.formattedSize)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground()
    }

    // MARK: - Options

    private var optionsCard: some View {
        Card(title: "Options", subtitle: "Odin's checkboxes, plus a few of our own") {
            VStack(alignment: .leading, spacing: 7) {
                optionToggle("Auto-reboot", "Restart the phone when the flash finishes",
                             isOn: $controller.options.autoReboot)
                optionToggle("Re-partition", "Rewrite the partition table from the PIT — only for recovery",
                             isOn: $controller.options.repartition)
                optionToggle("T-Flash", "Write to the inserted SD card instead of internal storage",
                             isOn: $controller.options.tFlash)
                optionToggle("Skip size check", "Don't verify each image fits its partition",
                             isOn: $controller.options.skipSizeCheck)
                optionToggle("Resume session", "Continue a session left open by a previous no-reboot flash",
                             isOn: $controller.options.resume)
                optionToggle("Verify checksums", "Check each file's appended MD5 before flashing — catches a corrupt download",
                             isOn: $controller.options.verifyChecksums)
                optionToggle("Verbose log", "Full transfer output, including USB detail",
                             isOn: $controller.options.verbose)
            }
        }
    }

    private func optionToggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Actions

    private var actionCard: some View {
        Card {
            VStack(spacing: 10) {
                if controller.state == .idle || controller.state == .preparing {
                    Button {
                        Task { await controller.prepare() }
                    } label: {
                        Label("Unpack & Map Partitions", systemImage: "shippingbox")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassAction(prominent: true)
                    .disabled(controller.state == .preparing || controller.selectedSlots.isEmpty)
                } else {
                    Button {
                        startFlashFlow()
                    } label: {
                        Label(
                            controller.state == .flashing ? "Flashing…" : "Flash \(controller.enabledPlan.count) Partitions",
                            systemImage: "bolt.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassAction(prominent: true)
                    .tint(controller.wipesUserData ? Theme.danger : Theme.accent)
                    .disabled(!monitor.isConnected || controller.state == .flashing || controller.enabledPlan.isEmpty)

                    if controller.state == .flashing {
                        Button("Cancel", role: .destructive) { controller.cancel() }
                            .controlSize(.small)
                    }
                }

                if !monitor.isConnected && controller.state != .idle {
                    Label("Connect a phone in download mode to enable flashing",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.caution)
                }

                if case .failed(let message) = controller.state {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Progress and plan

    private var progressCard: some View {
        Card(title: "Progress", subtitle: controller.statusText) {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: controller.overallProgress)
                    .progressViewStyle(.linear)

                HStack {
                    if let partition = controller.currentPartition {
                        Text("Writing \(partition)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("\(controller.currentPercent)%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(stateLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !controller.plan.isEmpty {
                            Text("\(controller.completedPartitions.count)/\(controller.enabledPlan.count) done")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: return "Waiting for firmware"
        case .preparing: return "Unpacking…"
        case .ready: return "Ready to flash"
        case .flashing: return "Flashing"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var planCard: some View {
        Card(
            title: "Partitions",
            subtitle: controller.plan.isEmpty
                ? "Unpack a firmware set to see the mapping"
                : (controller.wipesUserData
                   ? "\(controller.enabledPlan.count) selected — including partitions that erase your data"
                   : "\(controller.enabledPlan.count) of \(controller.plan.count) selected · data partitions excluded")
        ) {
            if controller.plan.isEmpty {
                Text("Nothing mapped yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(controller.plan) { entry in
                                partitionRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    // Follow the write, the same way the log follows its output —
                    // a 49-partition flash otherwise scrolls out of sight immediately.
                    .onChange(of: controller.currentPartition) { partition in
                        guard let partition else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(partition, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func partitionRow(_ entry: FlashPlanEntry) -> some View {
        let isDone = controller.completedPartitions.contains(entry.partitionName)
        let isActive = controller.currentPartition == entry.partitionName
        let isData = entry.pitEntry.isUserDataPartition
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { controller.setEnabled($0, forPartition: entry.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(controller.state == .flashing)

            Image(systemName: isDone ? "checkmark.circle.fill" : (isActive ? "arrow.up.circle.fill" : "circle"))
                .font(.system(size: 11))
                .foregroundStyle(isDone ? Theme.success : (isActive ? Theme.accent : Color.secondary.opacity(0.4)))

            Text(entry.partitionName)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isData ? Theme.danger : .primary)

            if isData {
                StatusPill(text: "erases your data", color: Theme.danger)
            }

            Text(entry.image.filename)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if isActive {
                Text("\(controller.currentPercent)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(entry.image.formattedSize)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.accent.opacity(0.1)
                      : (isData && entry.isEnabled ? Theme.danger.opacity(0.10) : Color.clear))
        )
        .opacity(entry.isEnabled ? 1 : 0.45)
    }

    // MARK: - Behaviour

    private func toggleSlot(_ slot: FirmwareSlot, enabled: Bool) {
        if enabled {
            // CSC and HOME_CSC write the same partitions, so they're exclusive.
            if slot.isCSCVariant {
                controller.selectedSlots.remove(.csc)
                controller.selectedSlots.remove(.homeCSC)
            }
            controller.selectedSlots.insert(slot)
        } else {
            controller.selectedSlots.remove(slot)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder holding the BL / AP / CP / CSC files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.loadPackage(at: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            // Dropping one of the tarballs is a natural mistake — take its folder.
            let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
            Task { @MainActor in controller.loadPackage(at: folder) }
        }
        return true
    }

    private func startFlashFlow() {
        Task {
            if PrivilegeBroker.hasPassword {
                if controller.wipesUserData {
                    confirmWipe.value = true
                } else {
                    beginFlash()
                }
            } else {
                authError.value = nil
                showAuth.value = true
            }
        }
    }

    private func authenticateThenFlash() {
        Task {
            // Clear the previous result first, so what's on screen always refers to
            // the attempt in progress rather than an earlier one.
            authError.value = nil
            isChecking.value = true
            let entered = password.value
            let ok = await PrivilegeBroker.validateAndStore(entered)
            isChecking.value = false
            password.value = ""
            if ok {
                showAuth.value = false
                if controller.wipesUserData {
                    confirmWipe.value = true
                } else {
                    beginFlash()
                }
            } else {
                authError.value = "That password wasn't accepted."
            }
        }
    }

    private func beginFlash() {
        Task { await controller.flash() }
    }
}

/// Asks for the admin password once. libusb has to claim the USB interface to talk
/// to the bootloader, and macOS only permits that as root.
struct AuthSheet: View {
    @Binding var password: String
    var errorText: String?
    var isChecking: Bool = false
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Administrator password required")
                        .font(.system(size: 13, weight: .semibold))
                    Text("macOS only lets root claim the phone's USB interface.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onConfirm)

            if isChecking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }

            Text("Valkyrie never stores this. It's used once to warm sudo's timestamp, and every later call runs non-interactively.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Authenticate", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isChecking)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
