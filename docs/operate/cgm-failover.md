# CGM failover (independent glucose)

Normally every glucose reading in faBolus arrives **through your pump** (the pump reads the CGM, the
phone reads the pump, the watches read the phone). That's a chain — and if any link drops, glucose
stops updating.

**CGM failover** adds an *independent* glucose feed as a backup, so a reading keeps flowing when:

- the **pump ↔ phone** Bluetooth link drops,
- the **watch ↔ phone** link drops, or
- the **pump ↔ sensor** link drops (but your phone's official CGM app is still getting data).

The pump-relayed reading stays **primary**. faBolus only shows the failover feed when the pump's
glucose goes **stale**, and it **never shows a stale reading as if it were current** (see
[Staleness](#staleness-age) below).

!!! warning "A backup, not a primary source — and not for dosing decisions"
    Failover exists to keep a number on screen when a link drops. Treat any reading — especially a
    failover one — as informational. See [Safety](../safety.md).

## What's possible for each sensor

Your sensor stays paired to the pump **and** to its official app; faBolus never unpairs anything.
Because of that, what an independent feed can be depends on the sensor:

| Sensor | Failover feed | Notes |
| --- | --- | --- |
| **Dexcom G7 / ONE+** | **Direct Bluetooth** (local, no internet) | Listens to the sensor's broadcast alongside the official app. Fastest, works even with no phone/internet. |
| **Dexcom G6** | **Dexcom Share** (cloud) | The G6 has no spare Bluetooth slot, so cloud is the only option — and Share is slow/unreliable. Last resort. |
| **FreeStyle Libre 2 / 3** | **LibreLinkUp** (cloud) | Share to a LibreLinkUp follower account. ~5 min. |
| **Eversense E3 / 365** | **Apple Health** | The Eversense app writes glucose to Apple Health; faBolus reads it. Requires enabling HealthKit — see below. |
| **Any CGM** | **Nightscout** (cloud) | If you already push your CGM to a Nightscout site. |

## Turn it on

1. Open **Settings → Glucose failover**.
2. Pick your sensor under **Failover CGM**.
3. For a cloud source (LibreLinkUp, Dexcom Share, Nightscout), tap **CGM account credentials** and
   enter your login. (Dexcom G7 direct and Eversense/Apple Health need no login — G7 just scans for
   the sensor; Apple Health will ask permission to read glucose.)
4. **Reopen the app** to start the failover source.

Cloud sources are **battery-aware**: while the pump feed is healthy they check rarely, and they ramp
up automatically the moment it goes stale. The Dexcom G7 direct link listens continuously (it's
cheap) so failover is instant.

!!! note "Eversense / Apple Health is opt-in (HealthKit)"
    HealthKit is **off by default** so the app builds and signs on a free Apple account. To use the
    Eversense (Apple Health) source you need the **paid Apple Developer Program**, then enable
    HealthKit for the app: uncomment the two `com.apple.developer.healthkit*` keys in `project.yml`
    (or turn on the **HealthKit** capability under Signing & Capabilities in Xcode) and rebuild.
    Every other source — Dexcom G7 direct, LibreLinkUp, Dexcom Share, Nightscout — works without it.

## On the watch

- **Apple Watch:** if your **Dexcom G7** is selected, the watch reads it **directly over Bluetooth**
  when your iPhone is out of range — so it keeps showing glucose on its own.
- **Garmin:** the Garmin remote shows whatever the phone sends it (so it benefits from failover as
  long as the phone is reachable). Direct-to-Garmin G7 Bluetooth is written but **paused pending
  on-device testing** (see the `direct-cgm/` scaffold in the faBolusGarmin repo).

## Staleness & age

Old readings are worse than no reading, so faBolus is strict about age:

- Every reading shows its **age** ("2 min ago") on the phone and both watches.
- A reading older than the **stale threshold** (default **6 minutes**) is **still shown, but
  greyed out with its age called out** — never presented as the current value.
- The same threshold governs the pump feed and every failover feed, so "stale" means one thing
  everywhere.

## Keeping it working

The Dexcom G7 decoders are **vendored** (copied) from LoopKit's G7SensorKit into
`Packages/G7SensorKit`, and the cloud clients (LibreLinkUp, Dexcom Share) are hand-ported from the
community projects. These are **pinned snapshots — they do not auto-update.** If a sensor's protocol
or a cloud API changes upstream, the matching source is updated by hand (re-copying the decoders, or
adjusting the request/parsing). Each file's header notes where it came from.

