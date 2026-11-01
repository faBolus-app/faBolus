#!/usr/bin/env bash
# Compiles the Connect IQ adapter (Packages/WatchLink/Sources/GarminTransport) against Garmin's iOS
# companion SDK. The SDK is licensed separately and isn't in the repository, so `swift build` compiles the
# adapter to nothing and no CI gate can check it; run this locally after changing the adapter or the link
# it drives.
#
#   CIQ_IOS_SDK=/path/to/connectiq-companion-app-sdk-ios-1.8.0 ./scripts/check-garmin-transport.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${CIQ_IOS_SDK:-$HOME/Code/vendor/connectiq-companion-app-sdk-ios-1.8.0}"
[ -d "$SDK/ConnectIQ.xcframework" ] || { echo "❌ ConnectIQ.xcframework not found under $SDK (set CIQ_IOS_SDK)" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/GarminTransport" "$WORK/Sources/WatchLink" "$WORK/Sources/RemoteProtocol"
cp -R "$SDK/ConnectIQ.xcframework" "$WORK/"
cp Packages/WatchLink/Sources/GarminTransport/*.swift "$WORK/Sources/GarminTransport/"
cp Packages/WatchLink/Sources/WatchLink/*.swift "$WORK/Sources/WatchLink/"
cp Packages/RemoteProtocol/Sources/RemoteProtocol/*.swift "$WORK/Sources/RemoteProtocol/"
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GarminTransportCheck", platforms: [.iOS(.v17)],
    products: [.library(name: "GarminTransport", targets: ["GarminTransport"])],
    targets: [
        .binaryTarget(name: "ConnectIQ", path: "ConnectIQ.xcframework"),
        .target(name: "RemoteProtocol"),
        .target(name: "WatchLink", dependencies: ["RemoteProtocol"]),
        .target(name: "GarminTransport", dependencies: ["WatchLink", "RemoteProtocol", "ConnectIQ"])
    ])
SWIFT
cd "$WORK"
xcodebuild -scheme GarminTransportCheck -destination 'generic/platform=iOS Simulator' -derivedDataPath "$WORK/dd" \
  build OTHER_SWIFT_FLAGS="-warnings-as-errors" >"$WORK/build.log" 2>&1 || { grep -E "error:" "$WORK/build.log" | head -20; exit 1; }
echo "✅ GarminTransport compiles against $(basename "$SDK")"
