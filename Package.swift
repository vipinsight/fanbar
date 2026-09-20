// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanBar", targets: ["FanBar"]),
        .executable(name: "FanBarHelper", targets: ["FanBarHelper"])
    ],
    targets: [
        .executableTarget(
            name: "FanBar",
            dependencies: ["SMCBridge"],
            path: "Sources/FanBar"
        ),
        .executableTarget(
            name: "FanBarHelper",
            dependencies: ["SMCBridge"],
            path: "Sources/FanBarHelper"
        ),
        .target(
            name: "SMCBridge",
            path: "Sources/SMCBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
