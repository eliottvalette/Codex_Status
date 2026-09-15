// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexMeter",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CodexMeter", targets: ["CodexMeter"]),
    ],
    targets: [
        .executableTarget(name: "CodexMeter"),
        .testTarget(
            name: "CodexMeterTests",
            dependencies: ["CodexMeter"]
        ),
    ]
)
