# What you'll need

A checklist of the hardware, accounts, and tools before you start the [build](build/index.md).
Don't worry if some terms are unfamiliar — the build guide explains each as you go.

## Hardware

<div class="grid cards" markdown>

-   :material-needle:{ .lg .middle } **A supported pump**

    ---

    faBolus currently supports the Tandem **t:slim X2**, plus the usual cartridges and infusion
    sets.

-   :material-cellphone:{ .lg .middle } **An iPhone**

    ---

    On **iOS 17 or later**, with a cable to connect it to your Mac.

-   :material-laptop:{ .lg .middle } **A Mac**

    ---

    Running a recent macOS — needed to run Xcode and build the app.

-   :material-watch:{ .lg .middle } **Optional: a Garmin remote**

    ---

    A **Garmin Venu 3S** if you want a wrist remote for bolusing and checking glucose without
    pulling out your phone.

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
| **Xcode 16+** | Builds the iPhone app | [Install Xcode](build/xcode.md) |
| **XcodeGen** | Generates the Xcode project from `project.yml` (`brew install xcodegen`) | [Install Xcode](build/xcode.md) |
| **[TandemKit](https://github.com/faBolus-app/TandemKit)** | The protocol/Bluetooth core the app is built on (downloaded alongside the app) | [Build the app](build/build-app.md#download) |
| **Connect IQ Mobile SDK for iOS** *(optional)* | Lets the iPhone talk to a Garmin watch — only needed if you want the Garmin remote. If it's absent, the app auto-builds without Garmin. | [Build the app](build/build-app.md#connectiq) |
| **Connect IQ device SDK** *(optional)* | Builds the Garmin watch app itself — only for Garmin users | [Build for Garmin](build/garmin-build.md) |

!!! note "For contributors validating the protocol"
    Verifying the protocol core (TandemKit's byte-exact tests) also needs a **JDK 17+** to run
    the pumpX2 `cliparser` oracle, and ideally a Bluetooth sniffer to capture a known-good
    pairing/bolus trace. This is only relevant if you're changing TandemKit itself — see its
    repo.

## Pairing codes

Your pump uses one of two pairing schemes; faBolus supports both and auto-selects:

- A **6-digit** code — t:slim X2 running firmware v7.7 or later (a modern JPAKE handshake). Most
  current pumps.
- A **16-character** code — older t:slim X2 (pre-v7.7).

See [Pairing your pump](setup/pairing.md).

---

Got everything? Head to the [Build guide :material-arrow-right:](build/index.md).
