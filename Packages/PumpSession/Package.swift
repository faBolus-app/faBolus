// swift-tools-version: 6.0
// PumpSession: the one owner of everything the app does with the pump. It runs TandemKit's link, keeps
// the pump's state, reads it on a priority queue, delivers boluses through the ledger, syncs history and
// handles the pump's alerts, and reports all of it as PumpEvents. PumpScript is a scripted pump under the
// same session, for tests and the debug-only mock.
//
// TandemKit is pinned by revision. To build against a local checkout with commits not yet pushed, point
// SwiftPM at it with a mirror (`swift package config set-mirror`, see CONTRIBUTING.md); the pin stays.
import PackageDescription

let package = Package(
    name: "PumpSession",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PumpSession", targets: ["PumpSession"]),
        .library(name: "PumpScript", targets: ["PumpScript"])
    ],
    dependencies: [
        .package(path: "../faBolusCore"),
        .package(path: "../HistoryStore"),
        .package(
            url: "https://github.com/faBolus-app/TandemKit.git", revision: "04db2d5a83de74a0667acfad1dfc1e7450546831")
    ],
    targets: [
        .target(
            name: "PumpSession",
            dependencies: [
                "faBolusCore", "HistoryStore",
                .product(name: "TandemMessages", package: "TandemKit"),
                .product(name: "TandemAuth", package: "TandemKit"),
                .product(name: "TandemLink", package: "TandemKit"),
                .product(name: "TandemBLE", package: "TandemKit")
            ]),
        .target(
            name: "PumpScript",
            dependencies: [
                .product(name: "TandemMessages", package: "TandemKit"),
                .product(name: "TandemLink", package: "TandemKit"),
                .product(name: "TandemBLE", package: "TandemKit")
            ]),
        .testTarget(
            name: "PumpSessionTests",
            dependencies: [
                "PumpSession", "PumpScript", "faBolusCore", "HistoryStore",
                .product(name: "TandemMessages", package: "TandemKit"),
                .product(name: "TandemLink", package: "TandemKit"),
                .product(name: "TandemBLE", package: "TandemKit")
            ])
    ]
)
