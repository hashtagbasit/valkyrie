import SwiftUI

struct CSCView: View {
    @EnvironmentObject private var model: CSCModel
    @StateObject private var confirm = Local(false)

    var body: some View {
        // A plain HStack rather than HSplitView: the split view was letting content
        // draw over the device status bar above it.
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    currentCard
                    portCard
                    applyCard
                }
                .padding(Theme.gutter)
            }
            .frame(width: 400)

            Divider()

            VStack(spacing: 14) {
                listCard
                if !model.log.isEmpty {
                    LogConsoleView(lines: model.log, onClear: { model.clearLog() })
                        .frame(maxHeight: 170)
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.refresh() }
        .confirmationDialog(
            "Change CSC to \(model.selectedCode ?? "")?",
            isPresented: confirm.binding,
            titleVisibility: .visible
        ) {
            Button("Change CSC", role: .destructive) { Task { await model.apply() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The phone will reboot. On some models a CSC change also performs a factory reset — back up first.\n\nOnly codes already in this firmware can be applied, and Knox is not affected.")
        }
    }

    // MARK: - Left column

    private var currentCard: some View {
        Card(
            title: "Current CSC",
            subtitle: model.currentCode == nil ? "Connect the phone with USB debugging on" : "Read from the connected device",
            accessory: AnyView(
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
            )
        ) {
            if let code = model.currentCode {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            if let country = model.currentCountry, !country.isEmpty {
                                Text(country).font(.system(size: 11.5))
                            }
                            Text("\(model.entries.count) codes in this firmware")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if let modem = model.modemCode {
                        Label(
                            modem == code ? "Modem confirms \(modem)" : "Modem reports \(modem) — reboot may be pending",
                            systemImage: modem == code ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(modem == code ? Theme.success : Theme.caution)
                    }
                }
            } else {
                Text(model.errorMessage ?? "No device detected.")
                    .font(.system(size: 11))
                    .foregroundStyle(model.errorMessage == nil ? .secondary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var portCard: some View {
        Card(title: "Diagnostic port", subtitle: "How the change reaches the modem") {
            VStack(alignment: .leading, spacing: 9) {
                if model.ports.isEmpty {
                    Label("No diagnostic port found", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.caution)
                    Text("Usually it appears as soon as USB debugging is on. If not, dial *#0808# on the phone, choose DM + ACM + ADB, then reconnect.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: Binding(
                        get: { model.selectedPort ?? "" },
                        set: { model.selectedPort = $0; model.readModemCode() }
                    )) {
                        ForEach(model.ports, id: \.self) { port in
                            Text(URL(fileURLWithPath: port).lastPathComponent).tag(port)
                        }
                    }
                    .labelsHidden()
                    Label("Port ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.success)
                }

                Button("Rescan Ports") { model.refreshPorts(); model.readModemCode() }
                    .controlSize(.small)
            }
        }
    }

    private var applyCard: some View {
        Card(title: "Apply") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let code = model.selectedCode {
                        Text(code)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        if code == model.currentCode {
                            StatusPill(text: "already active", color: Theme.success)
                        }
                    } else {
                        Text("nothing yet — pick one from the list")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Button {
                    confirm.value = true
                } label: {
                    Label(model.isApplying ? "Applying…" : "Change CSC", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassAction(prominent: true)
                .disabled(!model.canApply)

                if !model.canApply, let reason = model.blockedReason {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("No root, and Knox stays intact. Only codes already present in this firmware can be applied.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Right column

    private var listCard: some View {
        Card(
            title: "Available CSCs",
            subtitle: "Read from this device's own firmware · 🎙️ call recording · 💳 Samsung Wallet"
        ) {
            VStack(spacing: 8) {
                TextField("Search country, region or code", text: $model.search)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.filtered) { entry in
                            row(entry)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: .infinity)

                Text("Capability icons are community indications, not read from the phone — Samsung encrypts the feature files.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ entry: CSCEntry) -> some View {
        let isCurrent = entry.code == model.currentCode
        let isSelected = entry.code == model.selectedCode
        // A Button rather than onTapGesture: the gesture wasn't reliably reaching rows
        // inside the scrolling stack.
        return Button {
            model.selectedCode = entry.code
        } label: {
            HStack(spacing: 9) {
                Text(entry.code)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .frame(width: 42, alignment: .leading)
                    .foregroundStyle(isCurrent ? Theme.success : (isSelected ? Theme.accent : .primary))

                Text(entry.country ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)

                ForEach(entry.badges, id: \.symbol) { badge in
                    Text(badge.symbol)
                        .font(.system(size: 11))
                        .help(badge.help)
                }

                Spacer()

                if let region = entry.region {
                    Text(region)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if isCurrent {
                    StatusPill(text: "current", color: Theme.success)
                } else if isSelected {
                    StatusPill(text: "selected", color: Theme.accent, filled: true)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }
}
