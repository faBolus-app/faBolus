# How it works

A quick tour of the pieces and who's responsible for what. You don't need this to build or use
the app — it's here if you're curious or want to contribute.

## The big picture

**One rule organizes everything: only the iPhone talks to the pump.** The Apple Watch and Garmin
are *remotes* — they send requests to the iPhone, which owns the single Bluetooth connection,
runs the safety interlocks, and does the actual delivery.

```mermaid
flowchart LR
    Pump[("Insulin pump\n(currently Tandem t:slim X2 / Mobi)")]
    CGM[("CGM\n(optional direct failover)")]
    Phone["iPhone app\n(owns BLE, runs PumpX2Kit,\nconfirms every bolus)"]
    Watch["Apple Watch\nremote"]
    Garmin["Garmin\nwatch / Edge remote"]
    Widgets["Lock/Home\nwidgets + Siri"]

    Pump <-->|Bluetooth · signed| Phone
    CGM -.->|failover: direct BLE / cloud| Phone
    CGM -.->|failover: direct BLE| Watch
    Watch <-->|WatchConnectivity| Phone
    Garmin <-->|Connect IQ SDK| Phone
    Phone -->|App Group snapshot| Widgets
```

Glucose normally reaches the phone **through the pump**. An optional [CGM failover](operate/cgm-failover.md)
feed (dotted above) is a *backup* the app uses only when the pump's glucose goes stale — never in
place of a fresh pump reading.

## The repositories

```
PumpX2Kit  (Swift package — build once, reuse everywhere)
├── PumpX2Messages   framing, opcodes, request/response models, packetization, CRC/HMAC
├── PumpX2Auth       legacy pairing + EC-JPAKE (mbedTLS), per-command signing
└── PumpX2BLE        Core Bluetooth central (iOS + watchOS)

faBolus  (this repo, consumes PumpX2Kit via SPM)
├── Packages/faBolusCore/  contracts + models (RemoteCommand, RemoteLink, PumpBackend, GlucoseSource, GlucoseArbiter)
├── Packages/G7SensorKit/  Dexcom G7/ONE+ BLE decoders (vendored from LoopKit, MIT; LoopKit-free)
├── Packages/DexcomG6Kit/   Dexcom G5/G6/ONE passive BLE decoders (vendored from LoopKit/CGMBLEKit, MIT)
├── ios/faBolus/         iOS host app — owns the pump connection; tabbed modern UI
│   └── Data/Sources/    CGM failover impls: cloud (LibreLinkUp, Nightscout, Dexcom Share) + HealthKit + credentials
├── ios/faBolusWidgets/  Lock/Home Screen widgets (incl. Quick Bolus)
├── watch/faBolusWatch/  Apple Watch remote (WatchConnectivity + direct-G7 failover)
├── watch/faBolusWatchWidgets/  watch-face complication
├── Shared/                DexcomG7BLESource — passive G7 central reused by phone + watch
├── schema/                command.schema.json — the single source of truth for the contract
└── docs/                  this site

faBolusGarmin  (separate repo)
└── Connect IQ (Monkey C) remote — Garmin watches + Edge cycling computers; pairs to the iPhone app
```

!!! note "The Garmin app lives in its own repo"
    The Garmin (Monkey C) app lives in the separate
    **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)** repo. The *iPhone side* of the
    Garmin bridge (`GarminRemoteBridge`, the Connect IQ Mobile SDK dependency) is part of this app,
    so the two talk over the shared command contract.

## Who owns the pump

The iPhone owns the single Bluetooth control connection and runs **PumpX2Kit**. Remotes (Apple
Watch, Garmin) are thin clients that send commands to the phone; the phone runs the confirm
interlock and delivers. A standalone Apple Watch that runs PumpX2Kit on-watch (no phone) is
designed but not built.

## Glucose sources (CGM failover)

Glucose is normally one facet of the pump feed. On top of that, faBolus has a small **`GlucoseSource`**
seam (in `faBolusCore`, modeled on LoopKit's `CGMManager`) for *independent* CGM feeds used as a
[failover](operate/cgm-failover.md). Each source — Dexcom G7 and G6/G5/ONE passive Bluetooth, LibreLinkUp,
Nightscout, Dexcom Share, Apple Health — conforms to the same interface and is selected in Settings.

A **`GlucoseArbiter`** keeps the pump feed primary and switches to a source only when the pump's
glucose goes stale, deduping history so nothing is double-counted. One shared freshness rule
(`GlucoseFreshness`, default 6 min) governs the pump feed and every source, and a stale reading is
always shown *marked* (greyed, with its age) rather than as a current value. The reverse-engineered
Dexcom G7 decoders are vendored, LoopKit-free, in `Packages/G7SensorKit` and are read-only/passive —
they never authenticate, so they can't disturb the official app or the pump's own connection.

## The command contract

`schema/command.schema.json` defines the tiny phone↔remote protocol — fields like `kind`,
`requestId`, `units`, `carbsGrams`, `bgMgdl`, `confirmToken`, and `status`. Both the Swift side
(`faBolusCore/RemoteCommand.swift`) and the Monkey C side generate and validate against it, which is
what keeps the watch, Garmin, and phone from drifting apart.

## Byte-exact protocol

Every outgoing pump message in PumpX2Kit is asserted **byte-for-byte equal** to the pumpX2
`cliparser` oracle in tests, and CI re-runs this on every push. A scheduled CI job watches for
upstream protocol drift. This is what makes a hand-ported dosing protocol trustworthy — see the
[PumpX2Kit](https://github.com/faBolus-app/PumpX2Kit) repo.
