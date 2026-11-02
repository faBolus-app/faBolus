// swift-tools-version: 6.0
// faBolusCore — the stable, pump- and host-agnostic core of faBolus: the domain models and pump
// capabilities, the bolus calculator, the dose composer, the access policy and the remote-bolus ledger.
// PumpSession, the remote protocol and the app depend on this.
import PackageDescription

let package = Package(
    name: "faBolusCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "faBolusCore", targets: ["faBolusCore"])
    ],
    targets: [
        .target(name: "faBolusCore"),
        .testTarget(
            name: "faBolusCoreTests", dependencies: ["faBolusCore"],
            resources: [.process("Fixtures")])
    ]
)
