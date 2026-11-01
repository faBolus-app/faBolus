// swift-tools-version: 6.0
// WatchLink: the phone's link to a remote, as an explicit state machine (WatchLink), the host that answers
// the remote from the pump session, the bolus ledger and the alerts (RemoteHost), and the thin Connect IQ
// adapter under the link (GarminTransport, compiled only where the Connect IQ SDK is present).
//
// PumpSession pins TandemKit by revision; to build against a local checkout, use a SwiftPM mirror
// (CONTRIBUTING.md).
import PackageDescription

let package = Package(
    name: "WatchLink",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WatchLink", targets: ["WatchLink"]),
        .library(name: "RemoteHost", targets: ["RemoteHost"]),
        .library(name: "GarminTransport", targets: ["GarminTransport"])
    ],
    dependencies: [
        .package(path: "../RemoteProtocol"),
        .package(path: "../faBolusCore"),
        .package(path: "../Alerts"),
        .package(path: "../PumpSession")
    ],
    targets: [
        .target(name: "WatchLink", dependencies: ["RemoteProtocol"]),
        .target(
            name: "RemoteHost",
            dependencies: [
                "WatchLink", "RemoteProtocol", "faBolusCore", "Alerts",
                .product(name: "PumpSession", package: "PumpSession")
            ]),
        .target(name: "GarminTransport", dependencies: ["WatchLink", "RemoteProtocol"]),
        .testTarget(name: "WatchLinkTests", dependencies: ["WatchLink", "RemoteProtocol"]),
        .testTarget(
            name: "RemoteHostTests",
            dependencies: [
                "RemoteHost", "WatchLink", "RemoteProtocol", "faBolusCore", "Alerts",
                .product(name: "PumpSession", package: "PumpSession"),
                .product(name: "PumpScript", package: "PumpSession")
            ])
    ]
)
