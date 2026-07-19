# Architecture

```
PumpX2Kit  (Swift package — build once, reuse everywhere)
├── PumpX2Messages   framing, opcodes, request/response models, packetization, CRC/HMAC
├── PumpX2Auth       legacy pairing + EC-JPAKE (mbedTLS), per-command signing
└── PumpX2BLE        Core Bluetooth central (iOS + watchOS)

ControlX2iOS  (this repo, consumes PumpX2Kit via SPM)
├── ios/             iOS host app — owns the pump connection; Loop-style HUD
├── watch/           watchOS remote (WatchConnectivity)
├── garmin/          Connect IQ (Monkey C) remote
├── Shared/          RemoteCommand + RemoteLink (phone↔remote transport)
├── schema/          command.schema.json — the single source of truth for the contract
└── docs/            this site
```

## Who owns the pump
The iPhone owns the single BLE control connection and runs `PumpX2Kit`. Remotes (watch, Garmin)
are thin clients that send commands to the phone; the phone runs the confirm interlock and
delivers. (A standalone Apple Watch that runs `PumpX2Kit` on-watch is a later goal.)

## The command contract
`schema/command.schema.json` defines the tiny phone↔remote protocol (`kind`, `requestId`,
`units`, `carbsGrams`, `bgMgdl`, `confirmToken`, `status`, `deliveredUnits`). Both the Swift
side (`Shared/RemoteCommand.swift`) and the Monkey C side validate/generate against it, which
is what keeps watch/Garmin/phone from drifting.

## Byte-exact protocol
Every outgoing pump message in `PumpX2Kit` is asserted **byte-for-byte equal** to the pumpX2
`cliparser` oracle in tests, and CI re-runs this on every push. Upstream protocol drift is
caught by a scheduled CI alarm. See the PumpX2Kit repo.
