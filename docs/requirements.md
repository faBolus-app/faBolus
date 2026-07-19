# Requirements

## Hardware
- A **dedicated Tandem t:slim X2 or Mobi test pump** (never anyone's therapy pump), with
  saline cartridges, infusion sets, a scale, and a graduated container.
- An iPhone (iOS 17+). A paid Apple Developer account is recommended so sideloaded builds
  don't expire mid-project.
- Optional remotes: an Apple Watch (watchOS 10+) or a Connect IQ–capable Garmin watch.

## Software / toolchain
- Xcode 16+ (full install) for the app targets.
- [PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit) (Swift package) — consumed via SPM.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the
  Xcode project from `project.yml`.
- For the Garmin remote: the Connect IQ SDK.
- For validating the protocol core: a JDK 17+ (to run the pumpX2 `cliparser` oracle) and,
  ideally, a BLE sniffer to capture a known-good pairing/bolus trace.

## Pairing
- The pump uses either a **16-character** pairing code (older t:slim X2) or a **6-digit**
  code (t:slim X2 v7.7+ / Mobi, via JPAKE). Both are supported — see [Pairing](setup/pairing.md).
