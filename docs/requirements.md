# What you'll need

A checklist of the hardware, accounts, and tools before you start the [build](build/index.md).
Don't worry if some terms are unfamiliar — the build guide explains each as you go.

## Hardware

<div class="grid cards" markdown>

-   :material-needle:{ .lg .middle } **A Tandem pump**

    ---

    A Tandem **t:slim X2** or **Mobi**, plus the usual cartridges and infusion sets.

-   :material-cellphone:{ .lg .middle } **An iPhone**

    ---

    On **iOS 17 or later**, with a cable to connect it to your Mac.

-   :material-laptop:{ .lg .middle } **A Mac**

    ---

    Running a recent macOS — needed to run Xcode and build the app.

-   :material-watch:{ .lg .middle } **Optional: a watch remote**

    ---

    An **Apple Watch** (watchOS 10+) and/or a **Garmin venu3s** if you want a wrist remote.

</div>

## Accounts

- An **Apple ID**. A **free** one works (apps expire after 7 days); the **paid** Apple Developer
  Program ($99/year) means the app lasts a year and widgets/watch features are more reliable. See
  [Apple ID & Developer account](build/apple-developer.md).
- A free **Garmin developer account** — only if you're building the Garmin remote (to download
  its SDK and accept the license).

## Software / toolchain

| Tool | What it's for | Where |
| --- | --- | --- |
| **Xcode 16+** | Builds the iPhone / Apple Watch app | [Install Xcode](build/xcode.md) |
| **XcodeGen** | Generates the Xcode project from `project.yml` (`brew install xcodegen`) | [Install Xcode](build/xcode.md) |
| **[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit)** | The protocol/Bluetooth core the app is built on (downloaded alongside the app) | [Build the app](build/build-app.md#download) |
| **Connect IQ Mobile SDK for iOS** | Lets the iPhone talk to the Garmin watch (required by the app build) | [Build the app](build/build-app.md#connectiq) |
| **Connect IQ device SDK** | Builds the Garmin watch app itself | [Build for Garmin](build/garmin-build.md) |

!!! note "For contributors validating the protocol"
    Verifying the protocol core (PumpX2Kit's byte-exact tests) also needs a **JDK 17+** to run
    the pumpX2 `cliparser` oracle, and ideally a Bluetooth sniffer to capture a known-good
    pairing/bolus trace. This is only relevant if you're changing PumpX2Kit itself — see its
    repo.

## Pairing codes

Your pump uses one of two pairing schemes; faBolus supports both and auto-selects:

- A **6-digit** code — t:slim X2 v7.7+ and Mobi (via a modern JPAKE handshake). Most current
  pumps.
- A **16-character** code — older t:slim X2 (pre-v7.7).

See [Pairing your pump](setup/pairing.md).

---

Got everything? Head to the [Build guide :material-arrow-right:](build/index.md).
