// swift-tools-version: 6.0
// G7SensorKit — Dexcom G7 / ONE+ BLE message decoding, vendored from LoopKit/G7SensorKit (MIT) and
// stripped of its LoopKit / CGMManager coupling. This package carries ONLY the reverse-engineered
// protocol decoders (glucose + backfill messages, algorithm state, service/characteristic UUIDs);
// the BLE transport + the faBolus `GlucoseSource` conformance live in the app. Read-only / passive:
// there is no auth or control writing here.
import PackageDescription

let package = Package(
    name: "G7SensorKit",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "G7SensorKit", targets: ["G7SensorKit"]),
    ],
    targets: [
        .target(name: "G7SensorKit"),
        .testTarget(name: "G7SensorKitTests", dependencies: ["G7SensorKit"]),
    ]
)
