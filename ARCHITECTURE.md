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
├ BackendRegistry  (ios/faBolus/Data/BackendRegistry.swift)   — compile-time backend manifest (app-side)
├ Backends  (conform to PumpBackend)          ── swap the pump
│   • TandemBackend (ios/faBolus/Data/TandemBackend.swift, wraps TandemKit)  ← reference
│   • MockBackend   (ios/faBolus/Data/MockBackend.swift)                     ← copy this to start a new backend
├ Hosts  (answer the remote protocol)         ── who drives the pump for a remote
│   • faBolus (AppModel + GarminRemoteBridge)  ← reference host
│   • Loop host (open contribution, sketch in hosts/loop/)    ← "Loop instead of faBolus"
└ Remotes  (speak RemoteCommand)              ── host-agnostic
    • faBolusGarmin (separate repo)
```

`faBolusCore` holds only the stable contracts and platform-neutral models — no UI, no pump library,
no `import` of TandemKit. The app and every backend depend on it; that's what keeps the two seams
below stable while implementations churn. (The Apple Watch app/target is removed — gone on-device
since Phase 3/REMOTE-03, and the residual phone-side wire/transport/gate machinery retired in
Phase 17.5.)

## Seam 1 — `PumpBackend` (support a different pump)
The app talks only to `PumpBackend`, never to a pump library. A backend supplies a live
`PumpSnapshot` + histories, delivers/cancels boluses, computes recommendations, and reports
`activeNotifications` as neutral `PumpAlert`s. It also declares `PumpCapabilities` so the one UI
adapts (hide carbs mode / cancel / alerts / pairing when unsupported). TandemKit is just the engine
behind `TandemBackend` — the only app file that `import TandemMessages`; nothing else in the app
does. `TandemBackend`'s Tandem-only satellite files (BLE transport, read scheduling/catalog,
opcode/unsupported-read stores, response application) live under
`ios/faBolus/Data/Tandem/` for directory legibility — a folder/group move, not a compiler-enforced
import boundary: `project.yml` has one application target sourcing all of `ios/faBolus`, and
`TandemBackend.swift` itself stays at `Data/` root (a byte-identity-guarded dose path) and still
imports `TandemMessages` directly.

`ios/faBolus/Data/` itself is organized by concern (Phase 17-10): `App/` (AppModel extensions,
backend registration, pump-connection/session infra), `Remote/` (remote-host machinery —
`GarminRemoteBridge`, `AppRouter`, remote auth/policy), `CGM/` (glucose-source arbitration +
followers), `Diagnostics/` (BLE/session/connection logs), `Settings/` (persisted settings +
catalogs), and `Tandem/` (Tandem-only BLE/read/opcode satellites, moved in Phase 16). Only
`AppModel.swift` and `TandemBackend.swift` stay at the `Data/` root — the two byte-guarded
dose-path files that reorg deliberately left untouched.

Backends are registered in `BackendRegistry.enabled` — a **compile-time manifest** (iOS has no
dynamic plugins, so every backend is compiled in and selected at runtime; the default per build is
first in the list). See `CONTRIBUTING.md` → "Add a pump backend."

## Seam 2 — the Remote Protocol (support a different host, e.g. Loop)
Phone↔remote messages are the small JSON contract in **`schema/command.schema.json`** (the source
of truth), mirrored in Swift (`RemoteCommand`) and Monkey C (faBolusGarmin's `RemoteComm.mc`).
A **remote** (Garmin) only speaks this contract; a **host** answers it. faBolus's
`AppModel` + `GarminRemoteBridge` are the reference host. Any other app — e.g.
**Loop** — can host the same remotes by implementing the host side of the contract (map it to its
own dosing/status APIs). See `CONTRIBUTING.md` → "Host the remotes from another app."

**Safety is part of the contract:** any host MUST enforce a confirmation interlock and a max-bolus
clamp. The remote's 1-2-3 / hold confirm does not add a second human confirmation — the host
independently recomputes the dose from the carbs, rejects it if it diverges from the estimate the
remote showed, and clamps to the max-bolus limit (defense in depth, not a second human
confirmation).

## Repos
- **faBolus** (this repo) — the app, iPhone widgets, backends, `faBolusCore`, and the contract.
  (The Apple Watch remote is removed — see the note above.)
- **TandemKit** — the Tandem protocol/auth/BLE engine (a package `TandemBackend` wraps).
- **faBolusGarmin** — the Garmin remote (host-agnostic; consumes the contract schema).

## Where to extend it (open contributions)
These are the well-scoped seams to build on — each is a PR, not a fork. See `CONTRIBUTING.md` for
the step-by-step.
- **Add a pump backend** — support a non-Tandem pump by conforming to `PumpBackend` and registering a
  `BackendDescriptor`. Start from `MockBackend`. The whole app adapts via `PumpCapabilities`; nothing
  else changes.
- **Host the remotes from another app (e.g. Loop)** — answer the remote protocol from your own app so
  its Garmin remote (or any other remote you add) drives *your* dosing. `hosts/loop/` is a starting
  sketch, intentionally left for a contributor to complete against LoopKit (it must keep Loop's own
  confirmation + a max clamp).
- **Second-factor / transport work** — the contract is transport-agnostic; new remote transports
  or hardened confirmations are welcome as long as the interlocks hold.
