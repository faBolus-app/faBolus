# FAQ

??? question "Is this an official Tandem or Dexcom product?"
    No. faBolus is an independent, open-source project, not affiliated with Tandem Diabetes Care or
    Dexcom. It is experimental, not a medical device and not FDA-cleared. See [Safety](safety.md).

??? question "Is this the Tandem app, or controlX2?"
    Neither. faBolus is its own app. Its pump library, TandemKit, is a Swift port of James Woglom's
    pumpX2, the reverse-engineering controlX2 also builds on.

??? question "Which pumps work?"
    The Tandem t:slim X2, with either the 6-digit or the 16-character pairing code. faBolus doesn't
    connect to a Mobi.

??? question "Does it change my pump's settings?"
    No. It reads them. The only commands it sends that change anything are a bolus, a cancel, the carbs
    and glucose that go with a bolus, and clearing an alert you choose to clear.

??? question "Can I use faBolus and t:connect at the same time?"
    No. The pump pairs with one app at a time, and switching needs a new code from the pump each time. See
    [Pair your pump](setup/pairing.md#fabolus-and-tconnect).

??? question "Can faBolus get glucose without the pump?"
    Yes, as a backup: Dexcom Share, or a G6 or G7 read directly alongside the Dexcom app. It's used only
    while the pump's reading is old or missing. See [Backup CGM](setup/cgm.md).

??? question "Does it show mmol/L?"
    Not in this version: glucose is in mg/dL.

??? question "Do I need to be a programmer to build it?"
    No. The [build guide](build/index.md) walks through every step, with the few Terminal commands
    written out.

??? question "Do I need to pay Apple?"
    No. A free Apple account works, but the app has to be installed again every 7 days. The paid Apple
    Developer Program makes an install last a year and allows Time Sensitive notifications.

??? question "Does the Garmin talk to the pump?"
    No. The watch asks the phone, and the phone checks the request and talks to the pump. See
    [Garmin watch](remotes/garmin.md).

??? question "Which watches work?"
    The Garmin Venu 3S, the one watch the app is built and tested for.

??? question "Can a widget or the Live Activity bolus?"
    No. They show glucose and status. The Live Activity's bolus button only opens the app.

??? question "Can I bolus by carbs?"
    Yes, on the phone and the watch. The suggestion uses your pump's carb ratio, correction factor,
    target and active insulin, read from the pump. See [Bolus and cancel](operate/bolus.md).

??? question "How do you know the pump messages are right?"
    Every message TandemKit builds is tested byte for byte against pumpX2's reference implementation.
