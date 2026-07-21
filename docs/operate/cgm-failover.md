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
| **Dexcom G6 / G5 / ONE** | **Direct Bluetooth** (passive, local) | faBolus reads the transmitter **passively, alongside the official Dexcom app** (which stays the master) — local, no internet. The Dexcom app must be running. See [Dexcom G6 direct](#dexcom-g5g6one-direct) below. Fallbacks: [xDrip4iOS](#via-xdrip4ios) or Dexcom Share (cloud). |
| **FreeStyle Libre 2 / 3** | **LibreLinkUp** (cloud), or **xDrip4iOS** (local) | LibreLinkUp follower (~5 min). Better: if [xDrip4iOS](#via-xdrip4ios) reads your Libre, faBolus gets it **locally** via the App Group — no cloud. |
| **Eversense E3 / 365** | **Apple Health** | The Eversense app writes glucose to Apple Health; faBolus reads it. Requires enabling HealthKit — see below. |
| **Via xDrip4iOS** (Libre 1/2, Dexcom G5/G6/ONE, + more) | **Apple Health** or **App Group (local)** | Run [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) for your sensor; faBolus reads what it decodes. Biggest coverage boost — see [Via xDrip4iOS](#via-xdrip4ios) below. |
| **Any CGM** | **Nightscout** (cloud) | If you already push your CGM to a Nightscout site. |

## Turn it on

1. Open **Settings → Glucose failover**.
2. Pick your sensor under **Failover CGM**.
3. For a cloud source (LibreLinkUp, Dexcom Share, Nightscout), tap **CGM account credentials** and
   enter your login. (Dexcom G7 direct, Apple Health, and the xDrip App Group need no login — G7 scans
   for the sensor, Apple Health asks permission to read glucose, and the App Group reads on-device.)
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

## Via xDrip4iOS

[xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) is a universal CGM app. If you run it for
your sensor, faBolus can read what it decodes — giving you **every sensor xDrip supports** with no
extra work: FreeStyle **Libre 1/2** (direct, or via MiaoMiao/Bubble/Atom transmitters), **Dexcom
G5/G6/ONE**, and more. This is the biggest coverage boost, and — via the App Group path — the only
way to get a **local, low-latency Libre** feed (Libre binds to one Bluetooth owner, so faBolus can't
read it directly). Two ways to connect, both selectable under **Settings → Glucose failover**:

- **xDrip4iOS — Apple Health** *(easiest, works across developer accounts)*: enable "Store readings
  in HealthKit" in xDrip; faBolus reads them from Apple Health. xDrip writes in **real time** (unlike
  the official Dexcom app's 3-hour delay), so this is a genuine ~5-min feed. Requires HealthKit
  enabled on faBolus (same opt-in as the Eversense note above).
- **xDrip4iOS — App Group (local)** *(lowest latency, no cloud)*: xDrip's "Share to Loop" writes
  readings into a shared App Group that faBolus reads directly on-device — near-instant, works with
  no pump link and no internet. **Constraint:** App Groups are team-scoped, so faBolus and xDrip must
  be **built and signed under the same Apple Developer Team ID**, and you enable the app group on
  faBolus (in `project.yml`, uncomment the group matching xDrip's share type — **Loop**
  `group.com.$(DEVELOPMENT_TEAM).loopkit.LoopGroup` or **Trio**
  `group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group`; your team is substituted
  automatically). Set xDrip's "Share to Loop" type to match; faBolus reads whichever group has data.
  This is a self-compiler setup (both apps under your own team) — the standard Loop-ecosystem
  arrangement.

Which to choose: **App Group** if you self-compile both under one team (fastest, local); **Apple
Health** otherwise (near-real-time, no team matching). Either way the pump stays primary and the same
staleness/age rules apply.

## Dexcom G5/G6/ONE (direct)

faBolus can read a Dexcom **G6** (also G5 / ONE) **directly over Bluetooth**, locally — the "follow
the Dexcom app" approach, so you don't need a separate xDrip install:

- **Keep the official Dexcom app installed and running.** It stays the *master* (it authenticates and
  owns the session); faBolus connects as a second listener and **passively reads** the glucose the
  transmitter broadcasts. faBolus never authenticates or writes to the transmitter, so it can't
  disconnect the Dexcom app.
- Optionally enter your **transmitter ID** under Settings → Glucose failover → CGM account credentials
  (it just helps pick the right sensor if several Dexcoms are nearby). No login, no cloud.
- Decoding is vendored from LoopKit/CGMBLEKit (MIT), passive path only.

!!! warning "Needs the Dexcom app connected, and validate coexistence on-device"
    Without the official Dexcom app installed and connected to the transmitter, this gives no
    readings (it relies on that app keeping the session alive). And a G6 allows only a limited number
    of Bluetooth connections — **pump + Dexcom app + faBolus** all at once should be validated on your
    hardware. (The G7, which faBolus reads passively too, has no such limit.)

## On the watch

- **Apple Watch:** if your **Dexcom G7** is selected, the watch reads it **directly over Bluetooth**
  when your iPhone is out of range. Independently, if you enable **HealthKit on the watch**, the watch
  can read glucose (e.g. from **xDrip4iOS** via Apple Health, synced from the phone) on its own —
  phone-independent failover for *any* xDrip-supported sensor. (Health sync to the watch is a few
  minutes latent, so it's a backup, not a live feed.)
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
`Packages/G7SensorKit`; the G5/G6/ONE passive decoders from LoopKit's CGMBLEKit into
`Packages/DexcomG6Kit`; the cloud clients (LibreLinkUp, Dexcom Share) are hand-ported from the
community projects; and the xDrip App Group reader follows `JohanDegraeve/xdrip-client-swift`. These
are **pinned snapshots — they do not auto-update.** If a sensor's protocol or a cloud/xDrip format
changes upstream, the matching source is updated by hand. Each file's header notes where it came from.

