# Safety

!!! warning "Experimental"
    faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It
    is for experimental and demonstration use. Not medical advice — check every value against your pump
    and your clinician. If you build or use it, you assume all responsibility.

faBolus can tell your pump to deliver insulin. This page says what it does to keep that deliberate,
and what it leaves to the pump.

## Your pump stays in charge

- **The pump's own limits govern.** Its minimum bolus and the maximum bolus set on the pump apply to
  every dose. When faBolus knows your pump's maximum it checks against it first, so the error is clear;
  either way, the pump refuses a dose over its limit. faBolus adds no limit of its own, apart from an
  optional limit on bolus size from the watch that you can set.
- **The pump alarms on its own.** Its alarms and alerts appear on its own screen whether or not a phone
  is paired. faBolus shows them too, as a convenience. When faBolus can't run, for example once a
  self-built app's signing has run out, its notifications, the watch and the widgets stop; the pump's
  alarms don't.
- **Only signed commands deliver.** A bolus is a signed Bluetooth message the pump checks before it
  acts. faBolus never changes the pump's software.

## Before a bolus is sent

- **The pump is read again.** When you confirm, faBolus reads the pump's bolus settings and active
  insulin again. If the dose they give differs from the one you saw, it asks which to use.
- **You see the dose last.** A sheet shows the dose, what it's for and any notices, with a Deliver
  button. Nothing is sent until you press it.
- **Old glucose never fills a correction.** A reading past the freshness window you set is shown greyed,
  and the calculator won't correct from it unless you say so. Freshness counts from when the sensor
  measured the reading, not when faBolus received it.
- **Old pump values expire.** Active insulin older than 5 minutes and bolus settings older than 15 minutes
  aren't used without asking you.

## When an outcome is unknown

If the link drops after a bolus starts, faBolus may not know how much was delivered. Then:

- it tells you at once, and never calls the bolus failed unless the pump's history shows it never
  happened;
- it blocks every new bolus, including after the app restarts, until the pump's history settles it or
  you check the pump and confirm in the app.

## From the watch

- **Off by default.** Bolusing from the watch stays off until you turn it on in the app, and the app
  asks you to confirm each time you do. A switch makes the watch view-only.
- **A deliberate confirm.** Every watch bolus needs a 1 → 2 → 3 tap in order on the watch. A wrong tap
  starts over.
- **The phone checks every request.** A request must be less than 2 minutes old, and each one delivers at
  most once, even if it's sent again. For a carb bolus the phone works the dose out again from the pump's
  latest values and refuses it if it differs from what the watch showed by more than 0.10 U.

## Always available

- **Cancel** is never blocked: from the dashboard while a bolus delivers, or from the watch.
- **Read-only mode** hides the Bolus tab on the phone. Cancelling and clearing alerts still work.

## One controller at a time

The pump pairs with one app at a time. While faBolus is paired, the official t:connect app isn't, and
switching back means pairing again with a new code. See [Pair your pump](setup/pairing.md).

!!! note "Independent project"
    faBolus is not affiliated with Tandem Diabetes Care or Dexcom. See the [FAQ](faq.md).
