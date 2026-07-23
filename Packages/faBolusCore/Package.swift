// swift-tools-version: 6.0
// faBolusCore — the stable, pump- and host-agnostic contracts for faBolus: domain models,
// the PumpBackend interface + capabilities, and the phone↔remote command protocol. Backends
// (TandemBackend/PumpX2Kit, community backends) and hosts (faBolus, a Loop adapter) depend on this.
import PackageDescription

let package = Package(
    name: "faBolusCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v13)],
    products: [
        .library(name: "faBolusCore", targets: ["faBolusCore"]),
    ],
    targets: [
        .target(name: "faBolusCore"),
        .testTarget(name: "faBolusCoreTests", dependencies: ["faBolusCore"],
                    resources: [.process("Fixtures")]),
    ]
)
