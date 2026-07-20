# Architecture

faBolus is built around **two stable seams** so it can support many pumps and many host apps
without forking. Everything else is a plugin behind one of these.

```
┌ UI / app  (SwiftUI views + AppModel, ios/faBolus/)      ── pump- & host-agnostic
│     depends only on ↓
├ faBolusCore  (Packages/faBolusCore/) — the contracts + neutral models, an in-repo SwiftPM package
│   • PumpBackend        (Sources/faBolusCore/PumpBackend.swift)      — the pump seam
│   • PumpCapabilities   (Sources/faBolusCore/Models.swift)          — what a backend supports
│   • PumpAlert + domain models (Models.swift)                        — backend-neutral
│   • BackendDescriptor  (Sources/faBolusCore/BackendDescriptor.swift) — how a backend registers
│   • RemoteCommand      (Sources/faBolusCore/RemoteCommand.swift + schema/command.schema.json) — the remote seam
│   • RemoteLink         (Sources/faBolusCore/RemoteLink.swift)      — transport (WatchConnectivity)
├ BackendRegistry  (ios/faBolus/Data/BackendRegistry.swift)   — compile-time backend manifest (app-side)
├ Backends  (conform to PumpBackend)          ── swap the pump
│   • TandemBackend (ios/faBolus/Data/TandemBackend.swift, wraps PumpX2Kit)  ← reference
│   • MockBackend   (ios/faBolus/Data/MockBackend.swift)                     ← copy this to start a new backend
├ Hosts  (answer the remote protocol)         ── who drives the pump for a remote
│   • faBolus (AppModel + PhoneRemoteHost/GarminRemoteBridge)  ← reference host
│   • Loop host (open contribution, sketch in hosts/loop/)    ← "Loop instead of faBolus"
└ Remotes  (speak RemoteCommand)              ── host-agnostic
    • Apple Watch app        • faBolusGarmin (separate repo)
```

`faBolusCore` holds only the stable contracts and platform-neutral models — no UI, no pump library,
no `import` of PumpX2Kit. The app, the Apple Watch target, and every backend depend on it; that's
what keeps the two seams below stable while implementations churn.

## Seam 1 — `PumpBackend` (support a different pump)
The app talks only to `PumpBackend`, never to a pump library. A backend supplies a live
`PumpSnapshot` + histories, delivers/cancels boluses, computes recommendations, and reports
`activeNotifications` as neutral `PumpAlert`s. It also declares `PumpCapabilities` so the one UI
adapts (hide carbs mode / cancel / alerts / pairing when unsupported). PumpX2Kit is just the engine
behind `TandemBackend`; the app has **no** `import PumpX2Messages`.

Backends are registered in `BackendRegistry.enabled` — a **compile-time manifest** (iOS has no
dynamic plugins, so every backend is compiled in and selected at runtime; the default per build is
first in the list). See `CONTRIBUTING.md` → "Add a pump backend."

## Seam 2 — the Remote Protocol (support a different host, e.g. Loop)
Phone↔remote messages are the small JSON contract in **`schema/command.schema.json`** (the source
of truth), mirrored in Swift (`RemoteCommand`) and Monkey C (faBolusGarmin's `RemoteCommand.mc`).
A **remote** (Apple Watch, Garmin) only speaks this contract; a **host** answers it. faBolus's
`AppModel` + `PhoneRemoteHost`/`GarminRemoteBridge` are the reference host. Any other app — e.g.
**Loop** — can host the same remotes by implementing the host side of the contract (map it to its
own dosing/status APIs). See `CONTRIBUTING.md` → "Host the remotes from another app."

**Safety is part of the contract:** any host MUST enforce a confirmation interlock and a max-bolus
clamp. The remote's 1-2-3 / hold confirm is a *second* factor, not the only one.

## Repos
- **faBolus** (this repo) — the app, Apple Watch remote, iPhone widgets, backends, `faBolusCore`,
  and the contract.
- **PumpX2Kit** — the Tandem protocol/auth/BLE engine (a package `TandemBackend` wraps).
- **faBolusGarmin** — the Garmin remote (host-agnostic; consumes the contract schema).

## Where to extend it (open contributions)
These are the well-scoped seams to build on — each is a PR, not a fork. See `CONTRIBUTING.md` for
the step-by-step.
- **Add a pump backend** — support a non-Tandem pump by conforming to `PumpBackend` and registering a
  `BackendDescriptor`. Start from `MockBackend`. The whole app adapts via `PumpCapabilities`; nothing
  else changes.
- **Host the remotes from another app (e.g. Loop)** — answer the remote protocol from your own app so
  its watch/Garmin remotes drive *your* dosing. `hosts/loop/` is a starting sketch, intentionally left
  for a contributor to complete against LoopKit (it must keep Loop's own confirmation + a max clamp).
- **Second-factor / transport work** — the contract is transport-agnostic; new `RemoteLink` transports
  or hardened confirmations are welcome as long as the interlocks hold.
