import SwiftUI

@main
struct ValkyrieApp: App {
    @StateObject private var deviceMonitor = DeviceMonitor()
    @StateObject private var flashController = FlashController()
    @StateObject private var downloadModel = DownloadModel()
    @StateObject private var navigation = AppNavigation()
    @StateObject private var cscModel = CSCModel()

    var body: some Scene {
        WindowGroup("Valkyrie") {
            ContentView()
                .environmentObject(deviceMonitor)
                .environmentObject(flashController)
                .environmentObject(downloadModel)
                .environmentObject(navigation)
                .environmentObject(cscModel)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear { deviceMonitor.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
