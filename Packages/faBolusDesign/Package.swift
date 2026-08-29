// swift-tools-version: 6.0
// faBolusDesign — the shared, host-agnostic presentation layer: §13 glucose-band color tokens and
// accent/grey tokens. Depends on faBolusCore for the SINGLE classifier (GlucoseRange.classify) +
// thresholds (GlucoseThresholds) — logic stays in Core, presentation lives here (D-02). Every UI
// target (app, widgets, Live Activity, watch, mac) reads band colors from this one place instead of
// re-implementing them.
//
// IN-01 (09.29 review): the icon+word `BandIndicator` primitive this package used to also provide
// was deleted in Phase 09.29 (D-05 teardown) — the pinned VoiceOver zone word now lives inline as a
// composed `.accessibilityLabel`/`.accessibilityValue` on each glucose surface (see
// `StatusRingView.a11yLabel`), not as a shared view type here.
import PackageDescription

let package = Package(
    name: "faBolusDesign",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "faBolusDesign", targets: ["faBolusDesign"])
    ],
    dependencies: [
        .package(path: "../faBolusCore")
    ],
    targets: [
        .target(name: "faBolusDesign", dependencies: ["faBolusCore"]),
        .testTarget(name: "faBolusDesignTests", dependencies: ["faBolusDesign"])
    ]
)
