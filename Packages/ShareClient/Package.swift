// swift-tools-version:5.9
import PackageDescription

// Vendored from LoopKit/dexcom-share-client-swift (MIT) — the validated Dexcom Share follower Loop
// uses. Only the `ShareClient` core (login + fetchLast) is vendored; the LoopKit/HealthKit-coupled
// ShareGlucose+GlucoseKit, the CGMManager, and the UI are omitted. See Phase 6 in MIGRATION.md.
let package = Package(
    name: "ShareClient",
    platforms: [.iOS(.v15), .watchOS(.v9), .macOS(.v12)],
    products: [ .library(name: "ShareClient", targets: ["ShareClient"]) ],
    targets: [ .target(name: "ShareClient", path: "Sources/ShareClient") ]
)
