// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ZwiftShifter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZwiftShifterCore", targets: ["ZwiftShifterCore"]),
        .executable(name: "ZwiftShifter", targets: ["ZwiftShifter"])
    ],
    targets: [
        .target(name: "ZwiftShifterCore"),
        .executableTarget(name: "ZwiftShifter", dependencies: ["ZwiftShifterCore"]),
        .testTarget(name: "ZwiftShifterTests", dependencies: ["ZwiftShifterCore"])
    ]
)
