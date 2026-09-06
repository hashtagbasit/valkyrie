import SwiftUI

/// Odin's ID:COM box, modernised.
///
/// This reads the USB tree through IOKit, which needs no privileges — so the
/// connection state is live from launch without ever asking for a password.
struct DeviceStatusBar: View {
    @EnvironmentObject private var monitor: DeviceMonitor

    var body: some View {
        HStack(spacing: 12) {
            LiveDot(color: dotColor, active: monitor.isConnected)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let device = monitor.downloadModeDevice {
                StatusPill(text: device.identifierString, color: Theme.success)
            } else if !monitor.samsungDevices.isEmpty {
                StatusPill(text: "Not in download mode", color: Theme.caution)
            }

            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan the USB bus")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .background(barTint)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    private var dotColor: Color {
        if monitor.isConnected { return Theme.success }
        if !monitor.samsungDevices.isEmpty { return Theme.caution }
        return .secondary
    }

    private var barTint: Color {
        if monitor.isConnected { return Theme.success.opacity(0.07) }
        if !monitor.samsungDevices.isEmpty { return Theme.caution.opacity(0.07) }
        return Color.clear
    }

    private var headline: String {
        if let device = monitor.downloadModeDevice {
            return "\(device.name) — download mode"
        }
        if let samsung = monitor.samsungDevices.first {
            return "\(samsung.name) — connected, but not in download mode"
        }
        return "No Samsung device connected"
    }

    private var detail: String {
        if let device = monitor.downloadModeDevice {
            if let serial = device.serial, !serial.isEmpty {
                return "Serial \(serial) · ready to flash"
            }
            return "Ready to flash"
        }
        if !monitor.samsungDevices.isEmpty {
            return "Power off, then hold Volume Down + Volume Up and plug in the cable"
        }
        return "Connect a phone in download mode (Volume Down + Volume Up, then plug in USB)"
    }
}
