// swift-tools-version: 5.9
import PackageDescription

// HistoryStore — faBolus's own persistent glucose/insulin/carb history (SwiftData). faBolus OWNS the
// data (this is the on-device DB behind plotting + time-in-range, and the source the advisory kits read
// from). Speaks faBolusCore's neutral models; merges multi-source data by source priority + recency
// (same idea as GlucoseArbiter). Default retention is UNLIMITED (storage ≈ 1 MB/month); a clear-history
// action + optional auto-delete cover data-minimization. See ../../MIGRATION.md.
let package = Package(
    name: "HistoryStore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],   // SwiftData
    products: [.library(name: "HistoryStore", targets: ["HistoryStore"])],
    dependencies: [.package(path: "../faBolusCore")],
    targets: [
        .target(name: "HistoryStore", dependencies: ["faBolusCore"]),
        .testTarget(name: "HistoryStoreTests", dependencies: ["HistoryStore"]),
    ]
)
