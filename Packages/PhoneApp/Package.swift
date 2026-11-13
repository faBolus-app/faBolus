// swift-tools-version: 6.0
// PhoneApp: the phone app's state and wiring, kept out of the app target so it is tested with `swift test`.
// PhoneApp builds the pump session, the alert pipeline, the backup CGM source and the watch host at launch,
// in the order they need, and gives the views one thin observable state with no pump logic. WidgetContent is
// what the app publishes for its widgets and Live Activity; the widget extension links only it.
//
// TandemKit is pinned to a release tag, the same one PumpSession pins (SwiftPM refuses two different pins,
// so a bump that misses one fails to resolve). To build against a local checkout, use a SwiftPM mirror
// (CONTRIBUTING.md).
import PackageDescription

let package = Package(
    name: "PhoneApp",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PhoneApp", targets: ["PhoneApp"]),
        .library(name: "WidgetContent", targets: ["WidgetContent"])
    ],
    dependencies: [
        .package(path: "../faBolusCore"),
        .package(path: "../HistoryStore"),
        .package(path: "../PumpSession"),
        .package(path: "../Alerts"),
        .package(path: "../GlucoseSources"),
        .package(path: "../DexcomBLE"),
        .package(path: "../RemoteProtocol"),
        .package(path: "../WatchLink"),
        .package(
            url: "https://github.com/faBolus-app/TandemKit.git", exact: "0.8.0")
    ],
    targets: [
        .target(name: "WidgetContent", dependencies: ["faBolusCore"]),
        .target(
            name: "PhoneApp",
            dependencies: [
                "WidgetContent", "faBolusCore", "HistoryStore", "Alerts", "GlucoseSources", "RemoteProtocol",
                .product(name: "DexcomG6", package: "DexcomBLE"),
                .product(name: "PumpSession", package: "PumpSession"),
                .product(name: "PumpScript", package: "PumpSession"),
                .product(name: "WatchLink", package: "WatchLink"),
                .product(name: "RemoteHost", package: "WatchLink"),
                .product(name: "TandemBLE", package: "TandemKit"),
                .product(name: "TandemLink", package: "TandemKit")
            ]),
        .testTarget(name: "WidgetContentTests", dependencies: ["WidgetContent", "faBolusCore"]),
        .testTarget(
            name: "PhoneAppTests",
            dependencies: [
                "PhoneApp", "WidgetContent", "faBolusCore", "HistoryStore", "Alerts", "GlucoseSources",
                "RemoteProtocol",
                .product(name: "PumpSession", package: "PumpSession"),
                .product(name: "PumpScript", package: "PumpSession"),
                .product(name: "WatchLink", package: "WatchLink"),
                .product(name: "RemoteHost", package: "WatchLink"),
                .product(name: "TandemBLE", package: "TandemKit"),
                .product(name: "TandemLink", package: "TandemKit"),
                .product(name: "TandemMessages", package: "TandemKit")
            ])
    ]
)
