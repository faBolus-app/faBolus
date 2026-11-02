// swift-tools-version: 6.0
import PackageDescription

// HistoryStore — faBolus's own persistent glucose/insulin/carb history and the pump logbook (SwiftData),
// on the device only: the data behind the chart and time-in-range. Speaks faBolusCore's neutral models and
// merges multi-source glucose by source priority and recency (the same idea as GlucoseArbiter). The app
// keeps one day of glucose and can clear everything.
let package = Package(
    name: "HistoryStore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],  // SwiftData
    products: [.library(name: "HistoryStore", targets: ["HistoryStore"])],
    dependencies: [.package(path: "../faBolusCore")],
    targets: [
        .target(name: "HistoryStore", dependencies: ["faBolusCore"]),
        .testTarget(name: "HistoryStoreTests", dependencies: ["HistoryStore"])
    ]
)
