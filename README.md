# ControlX2iOS

iOS host app plus smartwatch remotes (Apple Watch and Garmin) for **remote bolusing** and status
viewing on a Tandem **t:slim X2 / Mobi** pump. The iPhone owns the pump's Bluetooth connection
(via [`PumpX2Kit`](../PumpX2Kit)); the watches are thin remotes that relay confirmed commands to
the phone.

> [!WARNING]
> **Independent, unofficial reimplementation — a bench proof-of-concept.** This is **not** a
> fork of, affiliated with, or endorsed by Tandem Diabetes Care or jwoglom's `controlX2`
> project. The name mirrors `controlX2` only to signal the parallel (`PumpX2Kit` ↔ pumpX2,
> `ControlX2iOS` ↔ controlX2). All testing is on a **dedicated test pump dispensing saline into a
> container on a scale — never on a body.**

## 📖 Documentation

**Full docs — a no-experience-required build guide, usage, customization, Siri & Shortcuts —
live at the documentation site:**

### 👉 https://zgranowitz.github.io/ControlX2iOS/

- [Safety first](docs/safety.md) — read before anything else.
- [Build it yourself](docs/build/index.md) — Apple account → Xcode → iPhone, step by step, plus
  the [Apple Watch](docs/build/apple-watch-build.md) and [Garmin](docs/build/garmin-build.md) apps
  (and a [command-line build](docs/build/advanced.md)).
- [Using the app](docs/operate/status.md) · [Settings & options](docs/customize/settings.md) ·
  [Siri & Shortcuts](docs/customize/shortcuts.md).

## Layout

```
ios/ControlX2/                 # iOS host app — owns the pump connection; tabbed Loop-style UI
ios/ControlX2Widgets/          # Lock/Home Screen widgets (incl. Quick Bolus)
watch/ControlX2Watch/          # Apple Watch remote (WatchConnectivity)
watch/ControlX2WatchWidgets/   # watch-face complication
Shared/                        # RemoteCommand + RemoteLink — the phone↔remote transport
schema/                        # THE phone↔remote message contract — single source of truth
docs/                          # the documentation site (MkDocs Material)
```

- The iOS app, widgets, Apple Watch app, and watch complication are all targets of one Xcode
  project, generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
  Depends on `PumpX2Kit` via SPM.
- The **Garmin** (Connect IQ / Monkey C) remote now lives in its own repo,
  **[PumpX2Garmin](https://github.com/zgranowitz/PumpX2Garmin)**; the iPhone-side bridge stays
  here and talks to it over the shared `schema/`.
- The three-plus widgets read a snapshot the app publishes to the App Group
  `group.com.zgranowitz.controlx2`; they can't drive Bluetooth, so they show the last published
  value and hide anything older than 6 minutes.

## Build (quick reference)

Full walkthrough: [docs/build](docs/build/index.md). In short:

```sh
git clone --recurse-submodules https://github.com/zgranowitz/PumpX2Kit.git
git clone https://github.com/zgranowitz/ControlX2iOS.git
# Place the Connect IQ Mobile SDK where project.yml expects it (see docs), then:
cd ControlX2iOS
xcodegen generate
open ControlX2.xcodeproj      # set your Team under Signing & Capabilities, then Run
```

Requires **Xcode 16+**, an **Apple ID** (free works; paid recommended), and — because the app
links Garmin's companion SDK — the **Connect IQ Mobile SDK for iOS**.

## Status

The protocol/BLE/auth core ([`PumpX2Kit`](../PumpX2Kit)) has met its Milestone 1 bench
definition-of-done (read-only monitor, JPAKE pairing, and a signed saline bolus validated on
hardware). This app layer is under active development on top of it.
