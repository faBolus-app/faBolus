// swift-tools-version: 6.0
// RemoteProtocol: the phone↔remote contract, version 2. Typed messages, their wire form, and the contract
// files a remote is built against (contract/: the field reference, one golden fixture per message, and the
// bolus calculator fixtures). It depends on nothing, so any remote and any transport can use it.
import PackageDescription

let package = Package(
    name: "RemoteProtocol",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"])
    ],
    targets: [
        .target(name: "RemoteProtocol"),
        .testTarget(name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"])
    ]
)
