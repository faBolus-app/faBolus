# Architecture

faBolus is an iPhone app that owns a Tandem pump's Bluetooth link, and a phone host for remotes that
ask it to act. Everything that compiles is a Swift package under `Packages/`; the app target in `ios/`
is views and wiring.

```text
ios/faBolus (SwiftUI views)          ios/faBolusWidgets (widgets, Live Activity)
        │                                     │
   PhoneApp ─ AppModel, settings, bolus flow  WidgetContent (what the app publishes)
        │
  ┌─────┼──────────────┬──────────────┬───────────────┐
PumpSession          Alerts      GlucoseSources     WatchLink ─ RemoteHost, GarminTransport
  │  └ HistoryStore                └ DexcomBLE, ShareClient        └ RemoteProtocol
TandemKit (pinned)
        └──────────── faBolusCore: domain types, the dose composer, the access policy ───┘
```

## Packages

| Package | What it owns |
| --- | --- |
| `faBolusCore` | The domain types every other package is written against: `PumpState` (each value an `Observed<T>` with its measurement time), `PumpModel` and `PumpCapabilities`, `BolusOutcome` and the durable bolus ledger, `PumpAlert`, `GlucoseArbiter`, and the dose code: `DoseComposer` and `AccessPolicy`. No UI, no pump library. |
| `PumpSession` | The one owner of the pump. It runs TandemKit's link, keeps the pump's state, reads it on a priority queue, delivers boluses through the ledger, syncs and searches history, handles the pump's alerts and the remote-clear decision, and reports all of it as `PumpEvent`s. `PumpScript` is a scripted pump under the same session, for tests and the debug-only mock. |
| `HistoryStore` | The pump history and logbook on the phone (SwiftData). |
| `Alerts` | The alert pipeline: a pure engine turns the session's events, the ledger and the glucose state into the notifications that should be showing, and a coordinator posts and withdraws them, persisting what it owes the OS across a relaunch. It also gives the in-app banners and the alerts the watch mirrors. |
| `GlucoseSources` | The backup CGM sources (Dexcom Share, direct G6, direct G7), the registry that builds the selected one, their settings and credentials, and the CGM test. |
| `DexcomBLE` | The direct Dexcom readers, from LoopKit's CGMBLEKit (passive mode) and G7SensorKit. They listen alongside the Dexcom app and never write to a sensor. |
| `ShareClient` | The Dexcom Share client, vendored from LoopKit. |
| `RemoteProtocol` | The phone↔remote contract, version 2: typed messages, their wire form, and the contract files in `contract/`. It depends on nothing. |
| `WatchLink` | The phone's link to a remote as an explicit state machine (`WatchLink`), the host that answers the remote from the session, the ledger and the alerts (`RemoteHost`), and the Connect IQ adapter (`GarminTransport`). |
| `PhoneApp` | The app's state and wiring, tested with `swift test`: `AppModel` (the only app state; views read it and act through it), `AppSettings`, the bolus flow, the first-launch wipe, the diagnostics export and the widget publisher. `WidgetContent` is what the widgets and the Live Activity read. |
| `faBolusDesign` | Glucose-band colours and the other shared presentation tokens. |

TandemKit, the pump protocol, is a separate repository. `PumpSession` and `PhoneApp` pin the same
release of it.

## The dose path

Every bolus, from the phone's bolus screen or a remote, goes through one path:

1. **`DoseComposer`** (faBolusCore) decides from a snapshot of the pump's state, the access context and
   the ledger's block. It applies `AccessPolicy`, the pump's link, cartridge and bounds, the optional
   remote size limit, the calculator inputs' freshness, glucose freshness and, for a remote, the
   request's age and the recompute against the remote's estimate. It's pure: the caller reads the pump
   first and passes the result in.
2. **The bolus ledger** (`DurableBolusLedger`) records the request before anything is sent. It owns one
   bolus at a time, at most one delivery per request ID, and the unknown-outcome block, which survives a
   restart until pump history settles it or the user confirms on the pump.
3. **`PumpSession`** sends the bolus permission, the carb and BG entries and the initiate, follows the
   delivery, and settles an unknown outcome from history.
4. **TandemKit** grants write risk per call (`PumpConnection.send(_:allowing:)`), refuses any signed write
   outside its short allowed list, and signs the message. Every message's bytes are tested against the
   pumpX2 oracle.

The pump's own limits govern; the app adds none of its own beyond the optional remote size limit. Cancel
is never gated. Like every send, it waits out the 5 s after the pump reports its communications suspended
(qualifying-event bit 19, as controlX2 does; `docs/UNVERIFIED-GUESSES.md` #22).

## The pump session

`PumpSession` is an actor and the only code that talks to TandemKit. TandemKit's link is a reducer
(`LinkReducer`) that owns every piece of link state: phases, the reconnect ladder, the one-in-flight
request queue, op-77 classification and probing. The session above it owns the pump's state, the reads,
the delivery and history, and records which commands this unit answers, so an unsupported read is sent
once and never again. One CoreBluetooth central per purpose, each with its own restore ID; the pump's is
`com.fabolus.app.pump`.

Freshness is a value the session is given (`FreshnessThresholds`): the glucose windows and the pump-status
window come from the user's settings; the IOB (5 min) and calculator (15 min) windows are fixed. Every
surface (phone, watch, widgets, Live Activity) judges age from the measurement time with the same
windows.

## The phone↔remote protocol

`Packages/RemoteProtocol/contract/` is the contract:

- `schema.json`, every message as JSON Schema;
- `fixtures/`, golden messages written by the Swift types (`GoldenFixtures`, checked by
  `GoldenFixtureTests`);
- `bolus_oracle_fixtures.jsonl`, the rows both calculators are tested against;
- `shared_constants.json`, the glucose bands and plausible range a remote keeps its own copy of.

A message is `{ "version": 2, "kind": …, "payload": … }`, with no floating-point numbers. The phone sends
status, config (the watch's preferences, sent in full on connect and on change), history on request,
and bolus outcomes; the remote sends polls, bolus requests, cancels and alert clears. Authentication
belongs to the transport. A version 1 message gets one reply in version 1's form, so an old watch shows
"Update watch app"; its cancel is still acted on.

faBolusGarmin vendors these files at a pinned faBolus commit (`contract/PIN`, updated with
`scripts/sync-contract.sh`), and its tests read every fixture. A field's meaning can't drift between the
two without one side's tests failing.

## The app

`AppEnvironment` builds everything at launch, in the order it's needed: the first-launch wipe (the new app
keeps the earlier app's bundle ID and removes everything it stored), the ledger, the session, the alerts,
the backup source and the watch host. Tests and the debug mock build the same environment over
`PumpScript`. Widgets and the Live Activity read a `WidgetSnapshot` the app publishes to the App Group;
they never reach the pump.

## Room for later

Some types carry cases for features not built: Mobi (`PumpModel.mobi`, with capabilities per model), an
extended bolus (`DoseRequest`'s shape), alarm escalation and Critical Alerts (`AlertEscalation`, the
interruption level). The protocol is transport-independent, so an Apple Watch or Mac remote is a new
transport and a new `RemoteHost` client, not a new format.

## The three repositories

- **faBolus**: the app, the widgets, the packages above and the contract.
- **[TandemKit](https://github.com/faBolus-app/TandemKit)**: the pump protocol (messages, pairing, signing,
  the link), MIT, usable by other apps.
- **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)**: the Garmin watch app, a remote built
  against the vendored contract.
