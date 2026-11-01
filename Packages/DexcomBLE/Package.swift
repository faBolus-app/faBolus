// swift-tools-version: 6.0
// Direct-Bluetooth Dexcom readers that work alongside the Dexcom app: G5/G6/ONE from LoopKit's
// CGMBLEKit (passive mode) in G6/, and G7/ONE+ from LoopKit's G7SensorKit in G7/, both MIT. Each
// folder keeps its upstream LICENSE. DexcomBLE holds what they share: the CoreBluetooth central, the
// event and command types, and the byte helpers. Nothing here writes to a sensor.
import PackageDescription

let package = Package(
    name: "DexcomBLE",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DexcomBLE", targets: ["DexcomBLE"]),
        .library(name: "DexcomG6", targets: ["DexcomG6"]),
        .library(name: "DexcomG7", targets: ["DexcomG7"])
    ],
    targets: [
        .target(name: "DexcomBLE", path: "Sources/DexcomBLE"),
        .target(name: "DexcomG6", dependencies: ["DexcomBLE"], path: "G6/Sources"),
        .target(name: "DexcomG7", dependencies: ["DexcomBLE"], path: "G7/Sources"),
        .testTarget(name: "DexcomBLETests", dependencies: ["DexcomBLE"], path: "Tests/DexcomBLETests"),
        .testTarget(
            name: "DexcomG6Tests", dependencies: ["DexcomG6", "DexcomBLE"], path: "G6/Tests",
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "DexcomG7Tests", dependencies: ["DexcomG7", "DexcomBLE"], path: "G7/Tests",
            resources: [.copy("Fixtures")])
    ]
)
