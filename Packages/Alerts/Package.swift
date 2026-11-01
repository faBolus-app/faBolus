// swift-tools-version: 6.0
// Alerts: the phone's alert pipeline. A pure engine turns PumpSession's events, the bolus ledger and the
// glucose state into the notifications that should be showing, and a coordinator posts and withdraws them
// through UserNotifications, persisting what it owes the OS so nothing is lost or posted twice across a
// relaunch. It also gives the in-app banner and the alerts the watch mirrors.
import PackageDescription

let package = Package(
    name: "Alerts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Alerts", targets: ["Alerts"])
    ],
    dependencies: [
        .package(path: "../faBolusCore")
    ],
    targets: [
        .target(name: "Alerts", dependencies: ["faBolusCore"]),
        .testTarget(name: "AlertsTests", dependencies: ["Alerts", "faBolusCore"])
    ]
)
