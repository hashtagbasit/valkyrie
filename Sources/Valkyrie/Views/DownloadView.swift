import SwiftUI

struct DownloadView: View {
    @EnvironmentObject private var model: DownloadModel
    @EnvironmentObject private var flashController: FlashController
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                lookupCard
                if let info = model.info {
                    latestCard(info)
                    if !info.history.isEmpty {
                        historyCard(info)
                    }
                }
                if let error = model.errorMessage {
                    Card {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var lookupCard: some View {
        Card(
            title: "Find firmware",
            subtitle: "Queries Samsung's own version index — the endpoint phones use for OTA checks"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Model").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        TextField("SM-F956B", text: $model.model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onSubmit { Task { await model.check() } }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Region (CSC)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            TextField("EUX", text: $model.region)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onSubmit { Task { await model.check() } }
                            Menu {
                                ForEach(DownloadModel.commonRegions, id: \.self) { code in
                                    Button(code) { model.region = code }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 14)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(" ").font(.system(size: 10.5))
                        Button {
                            Task { await model.check() }
                        } label: {
                            if model.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Check")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.model.isEmpty || model.region.isEmpty || model.isChecking)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(" ").font(.system(size: 10.5))
                        Button {
                            Task { await model.detectFromDevice() }
                        } label: {
                            if model.isDetecting {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Detect From Phone", systemImage: "iphone.gen3")
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.isDetecting)
                        .help("Read the model and region over adb")
                    }
                    Spacer()
                }

                if let build = model.detectedBuild {
                    Text("Phone currently runs \(build)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.success)
                }

                Text("The region code is printed in Settings → About phone → Software information, as the last part of the service provider code.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func latestCard(_ info: FirmwareVersionInfo) -> some View {
        Card(
            title: "Current firmware",
            subtitle: "\(info.model) · \(info.region)",
            accessory: AnyView(
                Group {
                    if let android = info.androidVersion {
                        StatusPill(text: "Android \(android)", color: Theme.accent)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                buildRow("AP", info.latest.ap, "System")
                buildRow("CSC", info.latest.csc, "Region")
                buildRow("CP", info.latest.cp, "Modem")

                Divider()
                downloadControls(for: info.latest)
            }
        }
    }

    @ViewBuilder
    private func downloadControls(for build: FirmwareBuild) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase.isBusy || model.phase == .finished {
                progressBlock
            }

            HStack(spacing: 8) {
                if model.phase.isBusy {
                    Button("Cancel", role: .destructive) { model.cancel() }
                        .controlSize(.small)
                } else {
                    Button {
                        chooseDestinationAndStart(build)
                    } label: {
                        Label("Download Firmware", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if model.phase == .finished {
                    if let folder = model.firmwareDirectory {
                        Button {
                            flashController.loadPackage(at: folder)
                            navigation.tab = .flash
                        } label: {
                            Label("Flash This Firmware", systemImage: "bolt.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button {
                        model.revealInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }

                Button {
                    copy(build.display)
                } label: {
                    Label("Copy Build", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                if let url = model.mirrorURL(for: build) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Mirror", systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }
                Spacer()
            }

            if !model.phase.isBusy {
                Toggle("Keep the .enc4 and .zip after unpacking", isOn: $model.keepIntermediateFiles)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
            }

            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Downloads come straight from Samsung's servers, then get verified against Samsung's checksum, decrypted and unpacked automatically. Intermediate files are deleted as each stage completes.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                Text(model.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.phase == .finished ? Theme.success : .secondary)
                Spacer()
                if model.totalBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: model.bytesReceived, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if !model.formattedRate.isEmpty {
                    Text(model.formattedRate)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
                if !model.estimatedTimeRemaining.isEmpty {
                    Text(model.estimatedTimeRemaining + " left")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseDestinationAndStart(_ build: FirmwareBuild) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"
        panel.message = "Choose where to save the firmware"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.start(build: build, into: directory)
    }

    private func buildRow(_ label: String, _ value: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .cardBackground()
    }

    private func historyCard(_ info: FirmwareVersionInfo) -> some View {
        Card(
            title: "Previous builds",
            subtitle: "\(info.history.count) earlier releases Samsung still lists"
        ) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(info.history) { build in
                        HStack(spacing: 8) {
                            Text(build.ap)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                copy(build.display)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy \(build.display)")

                            if let url = model.mirrorURL(for: build) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.borderless)
                                .help("Open \(build.ap) on samfw")
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .cardBackground()
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("Samsung's servers usually only serve the current build. Older ones generally need a mirror.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
