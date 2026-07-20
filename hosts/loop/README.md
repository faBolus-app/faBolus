# Loop host adapter (design scaffold — not built)

This directory sketches how **Loop** (or any app) can host the faBolus remotes (Apple Watch /
faBolusGarmin) by implementing the remote protocol, so the same watch apps work with Loop instead of
faBolus. It is **not compiled into faBolus** (it would pull in LoopKit); it's a reference for a Loop
integration that would live in Loop's own build, or graduate into an optional package here.

## How it works
The remotes only speak the JSON contract in `../../schema/command.schema.json`
(`RemoteCommand`). A host answers it. faBolus's `PhoneRemoteHost` / `GarminRemoteBridge` are the
reference host. A Loop adapter does the same, mapping the contract ↔ LoopKit:

| RemoteCommand | Loop mapping |
| --- | --- |
| `statusRead` → status payload | glucose/IOB/reservoir/battery/last bolus from LoopKit stores; trend from the CGM manager |
| `bolusRequest` (units) | Loop's manual-bolus dosing + **Loop's own authorization/confirmation** |
| `bolusRequest` (carbsGrams) | Loop's bolus calculator → units, then dose |
| `cancelBolus` | cancel the in-progress dose |
| `dismissAlert` | acknowledge the corresponding Loop/pump alert |

## Rules
- **Enforce the interlocks:** a confirmation step + max-bolus clamp on the host side. The remote's
  1-2-3/hold confirm is a second factor, not the only one.
- **Transport:** Apple Watch via `WatchConnectivity` (see `RemoteLink`); Garmin via the Connect IQ
  iOS SDK registered for the faBolusGarmin app UUID. The wire payload is identical either way.
- **Licensing:** keep this adapter compatible with LoopKit's license; it stays an optional module,
  separate from faBolus's MIT core.

## Upstream option
Long-term, Loop could adopt the remote protocol directly (it's small and versioned). Until then,
this adapter is the bridge. See `RemoteHost.swift.example` for the protocol shape + a skeleton.
