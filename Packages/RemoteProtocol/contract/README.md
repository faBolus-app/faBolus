# Phone↔remote protocol, version 2

The contract between the faBolus phone app and a remote (the Garmin watch app now; an Apple Watch or Mac
remote later). It doesn't depend on Connect IQ: a message is a JSON-shaped object that any transport can
carry, and authentication belongs to the transport.

The files here are the contract:

- `schema.json`: every message, as JSON Schema.
- `fixtures/`: golden messages, at least one per kind. Swift writes them
  (`RemoteProtocol.GoldenFixtures`, checked by `GoldenFixtureTests`); a remote's tests decode the
  phone's and produce the remote's exactly.
- `bolus_oracle_fixtures.jsonl`: the bolus calculator rows both calculators are tested against.
- `shared_constants.json`: values a remote keeps its own copy of and never receives: the glucose colour bands
  (faBolusCore `GlucoseThresholds`) and the plausible glucose range (`GlucosePlausibility`). The phone's tests
  and the remote's both check their copy against it.

A remote vendors these files from a pinned faBolus commit. faBolusGarmin keeps them in `contract/` with the
commit in `contract/PIN`; `scripts/sync-contract.sh` updates them and its CI checks them against the pin.

## Envelope

```json
{ "version": 2, "kind": "status", "payload": { } }
```

Each kind has its own payload, so no field changes meaning with the kind. No kind name is shared with
version 1, so neither version can take the other's message for one of its own.

- A message whose `version` is 1 (or that has no `version` and a version 1 kind) is from the old app. The
  phone answers each one once, in version 1's form, so the old watch shows "Update watch app" and stops
  offering a bolus. The watch shows "Update faBolus on the phone" and sends nothing back.
- A message with a higher version gets one `incompatible` reply. The watch shows "Update the watch app".
- A version 2 message that doesn't read is dropped and counted. A bolus request that doesn't read is
  answered as not delivered.

## Numbers

There are no floating-point numbers. Insulin is in milliunits (`mU`), the carb ratio in milligrams per
unit (`carbRatioMg`, 7.5 g/U is 7500), glucose in mg/dL, carbs in grams, times in epoch seconds. The
watch's 32-bit `Float` would otherwise change a dose in transit. A float where an integer belongs is
refused.

## Phone to remote

| Kind | When | Payload |
|---|---|---|
| `status` | on every change, as the answer to a poll, when the remote connects | live values, the bolus gate, the alerts |
| `config` | in full when the remote connects, on any change, and when a poll names another revision | the remote's preferences |
| `history` | only when a poll asks | glucose points, oldest first, at most 144 |
| `bolusOutcome` | on every move of a request, and when a poll names it | where the request stands |
| `dismissResult` | in answer to a dismiss | the pump's answer |
| `incompatible` | in answer to a message of another version | the version it sent |

### `status`

It names no request: a remote takes any status. Each value carries `at`, when it was measured by the
phone's clock. A remote judges a value's age as `sentAt - at` plus the time since the status arrived, so the
two clocks needn't agree. A value that hasn't been read, or whose time can't be trusted, is absent.

| Field | Meaning |
|---|---|
| `sentAt` | when the phone built it |
| `configRevision` | the revision of the phone's config; a remote holding another polls for it |
| `pumpLink` | `disconnected`, `scanning`, `connecting`, `authenticating`, `connected` |
| `glucose` | `mgdl`, `trend` (`flat`, `up`, `upup`, `up45`, `down`, `downdown`, `down45`; absent when none), `backup` (from the backup CGM), `at` |
| `iob`, `reservoir`, `lastBolus` | `mU`, `at` (`lastBolus.at` is when it was given) |
| `battery` | `percent`, `charging` (absent when unknown), `at` |
| `basal` | `suspended`, `mUPerHour` when not suspended, `at` |
| `calculator` | `carbRatioMg`, `isf`, `target`, `maxBolusMU`, `at` |
| `controlIQ` | `enabled`, `activity` (`normal`, `sleep`, `exercise`), `at` |
| `maxBasal` | `mUPerHour`, `at` |
| `lastAutoCorrection` | `at`: when Control-IQ last gave an automatic correction bolus, from the pump's history; absent when none is known |
| `bolus` | `canBolus`; `blockReason` when it's false; `active` (the bolus the pump is delivering, from any surface: `requestedMU`, `deliveredMU`, `startedAt`); `remoteLimitMU` when set |
| `alerts` | what the phone holds and has announced, most severe first: `id`, `title`, `body`, `severity` (`info`, `warning`, `critical`), `intent` (`quiet`, `alert`: shown, with or without vibration), `dismissable` (the remote may offer to clear it on the pump: true only once this pump is known to act on a remote clear, so a remote never makes the first try) |

`blockReason` is one of `pumpNotConnected`, `bolusInProgress`, `cartridgeNotReady`, `readOnly`,
`watchBolusOff`, `pumpCannotBolus`, `outcomeUnknown`, `deliveryLocked`. A remote shows a reason it doesn't
know generically. A cancel is never blocked.

### `config`

| Field | Meaning |
|---|---|
| `revision` | 16 hex digits of the SHA-256 of the rest of the config's canonical JSON: equal revisions are equal configs, so there's no counter to compare |
| `bolus` | `enabled` (bolusing from this remote), `readOnly` (remotes read-only), `defaultMode` (`carbs`, `units`), `unitsStepMU`, `carbStepG` |
| `screens` | `order`, `default` (`glance`, `glucose`, `clock`, `bolusonly`, `alerts`, `history`, `details`) |
| `details` | rows in order: `iob`, `reservoir`, `battery`, `cgm`, `lastBolus`, `carbRatio`, `isf`, `target`, `maxBolus`, `maxBasal`, `autoCorrection` (left out while none is known) |
| `chartHours` | ranges the chart cycles through, from 3, 6, 12, 24 |
| `freshness` | `iobMinutes`, `therapyMinutes`, `pumpStatusMinutes`: IOB, the calculator's settings, and the pump's status values (reservoir, battery, basal) count as current while younger than these, the phone's own windows in whole minutes rounded down; 0 counts nothing as current |
| `complication` | `slots` (up to three of `iob`, `reservoir`, `battery`, `basal`), `labels` (each slot's label names what it shows, as "IOB 1.25"; false shows the value alone) |
| `glucose` | `unit` (`mgdl`, `mmol`), `staleMinutes` (0 marks every reading stale), `hideDelayMinutes` (absent: never hide), `plotFloor`, `plotCeiling` |

The phone refuses a dose whatever the remote shows, so `bolus.enabled` and `bolus.readOnly` only hide the
button; the status's `bolus.canBolus` says the same at once.

### `bolusOutcome`

`requestId`, `outcome`, `requestedMU`, `deliveredMU` (when the pump has said), `message` (why, for a
refusal or failure), `sentAt`. `outcome` moves only forward:

```text
received ─▶ accepted ─▶ delivering ─▶ delivered / stopped
    │           │            └──────▶ unknown ─▶ delivered / stopped / failed
    │           └─▶ refused / failed / unknown / delivered / stopped
    └─▶ any of those
```

A message that would move a request backwards, or rewrite a settled one, is ignored, so a late or
duplicated message changes nothing. `unknown` means something that could deliver was sent and the phone
lost track; pump history settles it. `failed` means nothing was delivered, for a reason the phone knows.

The phone answers a request it has never seen with nothing, because the message carrying it may still
arrive. A remote stops waiting once the request would be refused as too old.

## Remote to phone

| Kind | Payload |
|---|---|
| `poll` | `configRevision` (absent when the remote has none: first launch or wiped storage), `awaiting` (the request it's waiting on), `history`, `freshGlucose`, `appVersion` |
| `bolus` | `requestId`, `sentAt` (when the user confirmed, by the remote's clock), `mode` (`units` with `mU`, or `carbs` with `carbsG` and `estimateMU`), `glucoseMgdl` (the reading the estimate used), `includeStaleGlucose` |
| `cancel` | `requestId`, `bolusRequestId` (when the remote started the bolus) |
| `dismiss` | `requestId`, `alertId` |

A bolus request may be sent again with the same `requestId` and `sentAt` until any outcome arrives; the
phone answers a repeat from its ledger and never delivers a request twice. It refuses a request sent more
than two minutes ago. The phone recomputes a `carbs` dose from its own inputs and refuses one that differs
from `estimateMU` by more than 0.10 U, or that corrects from a reading outside 40–400 mg/dL.
