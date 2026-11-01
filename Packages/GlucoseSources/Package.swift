// swift-tools-version: 6.0
// The backup CGM sources: Dexcom Share (cloud) and direct-Bluetooth Dexcom G6 and G7 (alongside the
// Dexcom app), the registry that builds the selected one, their settings and credentials, and the CGM
// test run from settings. GlucoseArbiter (faBolusCore) decides when a backup reading is shown.
import PackageDescription

let package = Package(
    name: "GlucoseSources",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "GlucoseSources", targets: ["GlucoseSources"])
    ],
    dependencies: [
        .package(path: "../faBolusCore"),
        .package(path: "../ShareClient"),
        .package(path: "../DexcomBLE")
    ],
    targets: [
        .target(
            name: "GlucoseSources",
            dependencies: [
                "faBolusCore", "ShareClient",
                .product(name: "DexcomBLE", package: "DexcomBLE"),
                .product(name: "DexcomG6", package: "DexcomBLE"),
                .product(name: "DexcomG7", package: "DexcomBLE")
            ]),
        .testTarget(
            name: "GlucoseSourcesTests", dependencies: ["GlucoseSources", "faBolusCore"],
            resources: [.copy("Fixtures")])
    ]
)
