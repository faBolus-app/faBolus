# FAQ

??? question "Is this an official Tandem or Dexcom product?"
    No. faBolus is an independent, open-source project — not affiliated with, endorsed by, or a
    product of Tandem Diabetes Care or Dexcom. It's a manual remote-bolus + status viewer, not an
    automated closed-loop system.

??? question "Is this the Tandem app, or controlX2?"
    No. It's an independent reimplementation for iOS, inspired by the naming of jwoglom's Android
    `controlX2` and built on the `pumpX2` protocol work. Not affiliated with or endorsed by
    either, nor by Tandem Diabetes Care.

??? question "Can I use this to dose insulin?"
    faBolus is experimental and in development — **not FDA-cleared**. Use it responsibly, with your
    clinician, and at your own risk. See [Safety](safety.md).

??? question "Which pumps are supported?"
    Tandem **t:slim X2** and **Mobi**, on a firmware version that's been pinned and tested. The
    protocol can break on a pump firmware update, so the app is treated as disposable against
    vendor changes.

??? question "Can faBolus get glucose without going through the pump?"
    Yes — optionally, as a **failover**. Glucose normally comes through the pump; you can add an
    independent backup feed that fills in when the pump, phone, or sensor link drops: **Dexcom G7 /
    ONE+** directly over Bluetooth (also on Apple Watch), or **LibreLinkUp** (Libre 2/3), **Dexcom
    Share** (G6), **Nightscout**, or **Apple Health** (Eversense). The pump stays the primary
    source. See [CGM failover](operate/cgm-failover.md).

??? question "Do I need to be a programmer to build it?"
    No. The [build guide](build/index.md) walks through every step in plain language — get an
    Apple account, install Xcode, and run the app on your iPhone.

??? question "Do I need to pay Apple?"
    Not necessarily. A **free** Apple ID works but the app expires after 7 days; the **paid**
    Apple Developer Program ($99/yr) lasts a year and makes widgets/watch features more reliable.
    See [Apple ID & Developer account](build/apple-developer.md).

??? question "Does the watch / Garmin talk to the pump directly?"
    No. The iPhone owns the connection; remotes relay commands to it. A standalone Apple Watch is
    designed but not built; the Garmin remote lives in the
    separate [faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin) repo and always relays
    through the phone.

??? question "Can I bolus by carbs?"
    Yes. Enter carbs (and optionally BG) and the app uses the pump's own calculator — carb ratio,
    correction factor (ISF), target, and IOB — to recommend a dose you then confirm. Entering
    units directly is always available too. See [Bolus & cancel](operate/bolus.md).

??? question "Can I use Siri or Shortcuts?"
    Yes, **read-only**: ask Siri for glucose/IOB/pump status, and use a set of value-returning
    Shortcuts actions in automations. There is no voice/automated bolus by design. See
    [Siri & Shortcuts](customize/shortcuts.md).

??? question "How do you know the protocol bytes are right?"
    Every outgoing message is tested **byte-for-byte** against the pumpX2 `cliparser` oracle, in
    CI, on every push.
