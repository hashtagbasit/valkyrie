import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case flash = "Flash"
    case download = "Download"
    case csc = "CSC"
    case tools = "Tools"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .flash: return "bolt.fill"
        case .download: return "arrow.down.circle.fill"
        case .csc: return "globe"
        case .tools: return "wrench.and.screwdriver.fill"
        case .about: return "heart.fill"
        }
    }
}

/// Tab selection, shared so a finished download can send the user straight to Flash.
@MainActor
final class AppNavigation: ObservableObject {
    @Published var tab: AppTab = .flash
}

struct ContentView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        return AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DeviceStatusBar()
            Divider()

            GlassGroup {
                switch navigation.tab {
                case .flash: FlashView()
                case .download: DownloadView()
                case .csc: CSCView()
                case .tools: ToolsView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(windowSurface)
        .background(WindowConfigurator().frame(width: 0, height: 0))
        .preferredColorScheme(appearance.colorScheme)
    }

    /// Glass needs something behind it, but not so little that the desktop reads
    /// through the app. `ultraThin` was transparent enough to make text compete with
    /// whatever window sat behind; `regular` keeps the frosted depth and stays legible.
    @ViewBuilder
    private var windowSurface: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var appearanceMenu: some View {
        Menu {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    appearanceRaw = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                }
            }
        } label: {
            Image(systemName: appearance.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("Appearance")
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Valkyrie")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Samsung firmware flasher for Apple Silicon")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: $navigation.tab) {
                ForEach(AppTab.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 480)

            appearanceMenu
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }

    /// The title bar reads as one continuous glass surface on macOS 26+.
    @ViewBuilder
    private var headerSurface: some View {
        if #available(macOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}
