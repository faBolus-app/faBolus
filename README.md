# faBolus

An iPhone app plus smartwatch remotes (Apple Watch and Garmin) for bolusing and status viewing on
a Tandem **t:slim X2 / Mobi** pump. The iPhone owns the pump's Bluetooth connection (via
[`PumpX2Kit`](../PumpX2Kit)); the watches are thin remotes that relay confirmed commands to the
phone.

> _Built by Zev and Tia in tandem._

> [!WARNING]
> **Experimental — in development.** faBolus is an independent, open-source project in development
> for experimental use. It is **not FDA-cleared**; if you build or use it, you assume all
> responsibility. Not affiliated with, endorsed by, or a product of **Tandem Diabetes Care or
> Dexcom**.

## 📖 Documentation

**Full docs — a no-experience-required build guide, usage, customization, Siri & Shortcuts —
live at the documentation site:**

### 👉 https://fabolus.org/

- [Safety](docs/safety.md) — read before anything else.
- [Build it yourself](docs/build/index.md) — Apple account → Xcode → iPhone, step by step, plus
  the [Apple Watch](docs/build/apple-watch-build.md) and [Garmin](docs/build/garmin-build.md) apps
  (and a [command-line build](docs/build/advanced.md)).
- [Using the app](docs/operate/status.md) · [Settings & options](docs/customize/settings.md) ·
  [Siri & Shortcuts](docs/customize/shortcuts.md).

## Layout

```
Packages/faBolusCore/        # in-repo SwiftPM package: the stable contracts + neutral models
                             #   (PumpBackend, PumpCapabilities, PumpAlert, RemoteCommand, RemoteLink)
ios/faBolus/                 # iOS host app — owns the pump connection; tabbed UI
ios/faBolus/Data/            # backends (TandemBackend, MockBackend) + BackendRegistry + hosts
ios/faBolusWidgets/          # Lock/Home Screen widgets (incl. Quick Bolus)
watch/faBolusWatch/          # Apple Watch remote (WatchConnectivity)
watch/faBolusWatchWidgets/   # watch-face complication
Shared/                      # WidgetShared — App Group snapshot shared with the widgets
schema/                      # THE phone↔remote message contract — single source of truth
hosts/                       # sketches for hosting the remotes from another app (e.g. Loop)
docs/                        # the documentation site (MkDocs Material)
```

New pumps and new host apps are added **in-tree behind stable interfaces, not by forking** — see
**[ARCHITECTURE.md](ARCHITECTURE.md)** for the two seams and **[CONTRIBUTING.md](CONTRIBUTING.md)**
for step-by-step "add a pump backend" / "host the remotes" guides.

- The iOS app, widgets, Apple Watch app, and watch complication are all targets of one Xcode
  project (`faBolus.xcodeproj`), generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen). Depends on `PumpX2Kit` via SPM.
- The **Garmin** (Connect IQ / Monkey C) remote lives in its own repo,
  **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)**; the iPhone-side bridge stays
  here and talks to it over the shared `schema/`.
- The widgets read a snapshot the app publishes to a shared App Group; they can't drive
  Bluetooth, so they show the last published value and hide anything older than 6 minutes.

## Build (quick reference)

Full walkthrough: [docs/build](docs/build/index.md). In short:

```sh
git clone --recurse-submodules https://github.com/faBolus-app/PumpX2Kit.git
git clone https://github.com/faBolus-app/faBolus.git
# Place the Connect IQ Mobile SDK where project.yml expects it (see docs), then:
cd faBolus
xcodegen generate
open faBolus.xcodeproj      # set your Team under Signing & Capabilities, then Run
```

Requires **Xcode 16+**, an **Apple ID** (free works; paid recommended), and — because the app
links Garmin's companion SDK — the **Connect IQ Mobile SDK for iOS**.

## Status

The protocol/BLE/auth core ([`PumpX2Kit`](../PumpX2Kit)) supports read-only monitoring, JPAKE
pairing, and a signed bolus path validated on hardware. This app layer is under active
development on top of it.
