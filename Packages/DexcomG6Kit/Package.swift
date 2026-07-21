// swift-tools-version: 6.0
// DexcomG6Kit — Dexcom G5 / G6 / ONE BLE glucose-message decoding, vendored from LoopKit/CGMBLEKit
// (MIT) and stripped to the **passive read path**: it decodes the glucose messages the transmitter
// broadcasts on the control characteristic while the official Dexcom app owns the authenticated
// session ("Follow Dexcom-app" / passive mode). No auth, no crypto, no control writes. faBolus's
// DexcomG6BLESource uses this to read a G6 locally alongside the official app.
import PackageDescription

let package = Package(
    name: "DexcomG6Kit",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "DexcomG6Kit", targets: ["DexcomG6Kit"]),
    ],
    targets: [
        .target(name: "DexcomG6Kit"),
        .testTarget(name: "DexcomG6KitTests", dependencies: ["DexcomG6Kit"]),
    ]
)
