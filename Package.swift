// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZwiftShift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZwiftShiftCore", targets: ["ZwiftShiftCore"]),
        .executable(name: "ZwiftShiftApp", targets: ["ZwiftShiftApp"]),
        .executable(name: "zwiftshift", targets: ["zwiftshift"]),
    ],
    targets: [
        .target(name: "ZwiftShiftCore", resources: [.copy("Web")],
                linkerSettings: [.linkedFramework("Network"), .linkedFramework("AppKit")]),
        .executableTarget(name: "ZwiftShiftApp", dependencies: ["ZwiftShiftCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "zwiftshift", dependencies: ["ZwiftShiftCore"]),
        .testTarget(name: "ZwiftShiftCoreTests", dependencies: ["ZwiftShiftCore"]),
    ],
    swiftLanguageModes: [.v6]
)
