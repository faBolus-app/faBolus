# ControlX2iOS

iOS host app plus smartwatch remotes (Apple Watch and Garmin Connect IQ) for **remote
bolusing** and status viewing on a Tandem **t:slim X2 / Mobi** pump. The iPhone owns the
pump's BLE connection (via [`PumpX2Kit`](../PumpX2Kit)); the watches are thin remotes that
relay confirmed commands to the phone.

> [!WARNING]
> **Independent, unofficial reimplementation — a bench proof-of-concept.** This is **not**
> a fork of, affiliated with, or endorsed by Tandem Diabetes Care or jwoglom's `controlX2`
> project. The name mirrors `controlX2` only to signal the parallel (`PumpX2Kit` ↔ pumpX2,
> `ControlX2iOS` ↔ controlX2). All testing is on a **dedicated test pump dispensing saline
> into a container on a scale — never on a body.**

## Layout

```
ios/       # iOS host app — owns the pump connection, full UI (Milestone 2)
watch/     # watchOS target — iPhone-hosted remote (Milestone 3), standalone config (Milestone 4)
garmin/    # Connect IQ (Monkey C) remote companion (Milestone 2)
schema/    # THE phone ↔ watch/garmin message contract — single source of truth
docs/      # architecture + bench notes
```

- `ios/` and `watch/` are targets in one Xcode project (standalone watchOS is a build
  config, not a separate repo).
- `garmin/` uses a different toolchain (Connect IQ SDK) but lives here so its message
  schema stays in lockstep with the iOS host — the whole reason to co-locate.
- Depends on `PumpX2Kit` via SPM (pin a released version).

## Status

Not started — blocked on `PumpX2Kit` Milestone 1 reaching its bench definition-of-done.
This repo is scaffold-only for now. Requires **full Xcode + a paid Apple Developer
account** (and, for `garmin/`, the Connect IQ SDK) to build.
