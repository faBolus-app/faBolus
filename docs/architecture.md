# How it works

A quick tour of the pieces and who's responsible for what. You don't need this to build or use
the app — it's here if you're curious or want to contribute.

## The big picture

**One rule organizes everything: only the iPhone talks to the pump.** The Apple Watch and Garmin
are *remotes* — they send requests to the iPhone, which owns the single Bluetooth connection,
runs the safety interlocks, and does the actual delivery.

```mermaid
flowchart LR
    Pump[("t:slim X2 / Mobi\n(saline bench pump)")]
    Phone["iPhone app\n(owns BLE, runs PumpX2Kit,\nconfirms every bolus)"]
    Watch["Apple Watch\nremote"]
    Garmin["Garmin venu3s\nremote (PumpX2Garmin)"]
    Widgets["Lock/Home\nwidgets + Siri"]

    Pump <-->|Bluetooth · signed| Phone
    Watch <-->|WatchConnectivity| Phone
    Garmin <-->|Connect IQ SDK| Phone
    Phone -->|App Group snapshot| Widgets
```

## The repositories

```
PumpX2Kit  (Swift package — build once, reuse everywhere)
├── PumpX2Messages   framing, opcodes, request/response models, packetization, CRC/HMAC
├── PumpX2Auth       legacy pairing + EC-JPAKE (mbedTLS), per-command signing
└── PumpX2BLE        Core Bluetooth central (iOS + watchOS)

ControlX2iOS  (this repo, consumes PumpX2Kit via SPM)
├── ios/ControlX2/         iOS host app — owns the pump connection; tabbed Loop-style UI
├── ios/ControlX2Widgets/  Lock/Home Screen widgets (incl. Quick Bolus)
├── watch/ControlX2Watch/  Apple Watch remote (WatchConnectivity)
├── watch/ControlX2WatchWidgets/  watch-face complication
├── Shared/                RemoteCommand + RemoteLink (phone↔remote transport)
├── schema/                command.schema.json — the single source of truth for the contract
└── docs/                  this site

PumpX2Garmin  (separate repo)
└── Connect IQ (Monkey C) remote for the venu3s — pairs to the iPhone app
```

!!! note "The Garmin app moved to its own repo"
    The Garmin (Monkey C) watch app used to live in `ControlX2iOS/garmin/`; it now lives in the
    separate **[PumpX2Garmin](https://github.com/zgranowitz/PumpX2Garmin)** repo. The
    *iPhone side* of the Garmin bridge (`GarminRemoteBridge`, the Connect IQ Mobile SDK
    dependency) is still part of this app, so the two continue to talk over the shared command
    contract.

## Who owns the pump

The iPhone owns the single Bluetooth control connection and runs **PumpX2Kit**. Remotes (Apple
Watch, Garmin) are thin clients that send commands to the phone; the phone runs the confirm
interlock and delivers. A standalone Apple Watch that runs PumpX2Kit on-watch (no phone) is
designed but not built — see [Independent Apple Watch](design/independent-watch.md).

## The command contract

`schema/command.schema.json` defines the tiny phone↔remote protocol — fields like `kind`,
`requestId`, `units`, `carbsGrams`, `bgMgdl`, `confirmToken`, and `status`. Both the Swift side
(`Shared/RemoteCommand.swift`) and the Monkey C side generate and validate against it, which is
what keeps the watch, Garmin, and phone from drifting apart.

## Byte-exact protocol

Every outgoing pump message in PumpX2Kit is asserted **byte-for-byte equal** to the pumpX2
`cliparser` oracle in tests, and CI re-runs this on every push. A scheduled CI job watches for
upstream protocol drift. This is what makes a hand-ported dosing protocol trustworthy — see the
[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit) repo.
