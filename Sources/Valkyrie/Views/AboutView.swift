import SwiftUI

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/hashtagbasit/valkyrie")!
    private let kofiURL = URL(string: "https://ko-fi.com/aimalb")!
    private let paypalURL = URL(string: "https://paypal.me/Basit2000")!

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "1.0.0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                supportCard
                projectCard
                creditsCard
            }
            .padding(Theme.gutter)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        Card {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 72, height: 72)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.accent.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Valkyrie")
                            .font(.system(size: 26, weight: .bold))
                        Text("v\(version)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("Flash Samsung Galaxy firmware natively on Apple Silicon — no Windows, no virtual machine, no Odin.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        StatusPill(text: "Open source", color: Theme.success)
                        StatusPill(text: "MIT", color: Theme.accent)
                        StatusPill(text: "Apple Silicon", color: Theme.accent)
                    }
                    .padding(.top, 2)

                    Button {
                        NSWorkspace.shared.open(repositoryURL)
                    } label: {
                        Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .glassAction()
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                Spacer()
            }
        }
    }

    // MARK: - Support

    private var supportCard: some View {
        Card(
            title: "Support the project",
            subtitle: "Built and maintained by one person, in spare time, for free"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Valkyrie is a solo, unfunded project. There's no company behind it and nothing is sold — every device it supports came out of someone's evening. If it saved you buying a Windows licence, rescued a phone, or spared you a paywalled firmware download, a coffee genuinely helps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(kofiURL)
                    } label: {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassAction(prominent: true)
                    .controlSize(.large)

                    Button {
                        NSWorkspace.shared.open(paypalURL)
                    } label: {
                        Label("PayPal", systemImage: "creditcard.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassAction()
                    .controlSize(.large)
                }

                HStack(spacing: 16) {
                    linkRow(symbol: "cup.and.saucer", label: "ko-fi.com/aimalb", url: kofiURL)
                    linkRow(symbol: "creditcard", label: "PayPal — Basit2000", url: paypalURL)
                }
                .padding(.top, 2)
            }
        }
    }

    private func linkRow(symbol: String, label: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label).font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }

    // MARK: - What it does

    private var projectCard: some View {
        Card(title: "What it does", subtitle: "Everything Odin does on Windows, and a few things it doesn't") {
            VStack(alignment: .leading, spacing: 9) {
                feature("bolt.fill", "Flash", "Drag in a firmware folder. Checksums verified, partitions mapped from the PIT, data partitions excluded unless you ask.")
                feature("arrow.down.circle.fill", "Download", "Straight from Samsung's servers — resumable, CRC-checked, decrypted and unpacked automatically. No mirrors, no paywalls.")
                feature("globe", "CSC", "Change the sales code over the modem, without root, without tripping Knox, and without wiping your data.")
                feature("wrench.and.screwdriver.fill", "Tools", "Inspect the partition table, read it off the phone, and see exactly what's on the USB bus.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground()
    }

    // MARK: - Credits

    private var creditsCard: some View {
        Card(title: "Standing on other people's work", subtitle: "None of this starts from nothing") {
            VStack(alignment: .leading, spacing: 7) {
                credit("Bundled", "The flash engine, lz4 and libusb ship inside this app — nothing to install.")
                credit("Heimdall", "Benjamin Dobell, Glass Echidna — the original Odin-protocol implementation. MIT.")
                credit("Maintained fork", "Henrik Grimler, who kept it alive for years.")
                credit("Apple Silicon fix", "aljosasavic/heimdall-apple-silicon — clears the stalled USB pipe that made large partitions fail on macOS.")
                credit("Firmware protocol", "Samloader and Bifrost, for working out how Samsung's servers actually talk.")
                credit("libusb / lz4", "LGPL-2.1 and BSD-2-Clause respectively, bundled unmodified.")

                Divider().padding(.vertical, 2)

                Text("Valkyrie is MIT licensed. Flashing firmware can wipe data and, if interrupted, brick a device — use firmware built for your exact model and proceed at your own risk.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func credit(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
