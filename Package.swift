// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexQuotaKit", targets: ["CodexQuotaKit"]),
        .executable(name: "CodexBar", targets: ["CodexBar"])
    ],
    targets: [
        .target(name: "CodexQuotaKit"),
        .executableTarget(
            name: "CodexBar",
            dependencies: ["CodexQuotaKit"]
        ),
        .testTarget(
            name: "CodexQuotaKitTests",
            dependencies: ["CodexQuotaKit"]
        )
    ]
)
