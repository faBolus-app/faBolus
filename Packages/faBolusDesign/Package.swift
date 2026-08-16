// swift-tools-version: 6.0
// faBolusDesign — the shared, host-agnostic presentation layer: §13 glucose-band color tokens,
// accent/grey tokens, and the redundant icon+word band-encoding primitive. Depends on faBolusCore
// for the SINGLE classifier (GlucoseRange.classify) + thresholds (GlucoseThresholds) — logic stays
// in Core, presentation lives here (D-02). Every UI target (app, widgets, Live Activity, watch, mac)
// reads band colors from this one place instead of re-implementing them.
import PackageDescription

let package = Package(
    name: "faBolusDesign",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "faBolusDesign", targets: ["faBolusDesign"]),
    ],
    dependencies: [
        .package(path: "../faBolusCore"),
    ],
    targets: [
        .target(name: "faBolusDesign", dependencies: ["faBolusCore"]),
        .testTarget(name: "faBolusDesignTests", dependencies: ["faBolusDesign"]),
    ]
)
