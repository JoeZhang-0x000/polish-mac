// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Polish",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Polish",
            path: "Sources/Polish",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
