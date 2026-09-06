// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Valkyrie",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Valkyrie",
            path: "Sources/Valkyrie",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
