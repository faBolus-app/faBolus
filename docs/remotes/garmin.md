# Garmin remote

A Connect IQ (Monkey C) companion for the **Garmin venu3s**. It's a **thin remote**: it messages
the iPhone host via the Connect IQ mobile SDK, and the phone runs the confirm interlock and
delivers through PumpX2Kit. To build and install it, see
[Build the Garmin remote](../build/garmin-build.md).

!!! note "The Garmin app lives in its own repo"
    The Garmin watch app is maintained in the separate
    **[faBolusGarmin](https://github.com/zgranowitz/faBolusGarmin)** repo (it used to live in
    `faBolus/garmin/`). The *iPhone side* of the bridge is still part of the faBolus app,
    so the two talk over the shared command contract as before.

<div class="cx2-shots" markdown>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin glance](../assets/screenshots/garmin-glance.svg)
  <figcaption>Glance</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin history](../assets/screenshots/garmin-history.svg)
  <figcaption>History plot</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin details](../assets/screenshots/garmin-details.svg)
  <figcaption>Details</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin alerts](../assets/screenshots/garmin-alerts.svg)
  <figcaption>Alerts</figcaption>
</figure>
</div>

## The screens (swipe up/down to move between them)

- **Glance** — current glucose + a drawn, range-colored trend arrow, and a **Bolus** button.
- **Alerts** — active pump alerts/alarms; **tap a row to clear** one.
- **History** — a Dexcom-style plot; **tap to cycle** the window **3 → 6 → 12 h**.
- **Details** — last bolus, Active Insulin, reservoir, battery, and an alert count.

### Reorder the screens / pick the default

The **order** of these screens and **which one opens first** are configurable from the phone:
**Settings → Garmin remote → Screen order**. Drag to reorder and choose the screen that opens
first. The layout is sent to the watch on its next status update and is remembered on the watch
(it survives restarts and offline launches). Default: Glance → Alerts → History → Details,
opening on Glance.

## Input model (venu3s)

The venu3s delivers screen taps as high-level events, so the app uses:

- **Tap** a button or target (bolus −/+, Deliver, the numbered confirm circles, an alert row).
- **Swipe** up/down to move between screens.

## Bolus flow

<div class="cx2-shots" markdown>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin bolus entry](../assets/screenshots/garmin-bolus.svg)
  <figcaption>Set units or carbs</figcaption>
</figure>
<figure class="cx2-shot watch" markdown="span">
  ![Garmin 1-2-3 confirm](../assets/screenshots/garmin-confirm.svg)
  <figcaption>Tap 1 → 2 → 3 to confirm</figcaption>
</figure>
</div>

<ol class="cx2-steps">
<li>Open <strong>Bolus</strong>, tap the mode chip to switch <strong>Units / Carbs</strong>, tap <strong>−/+</strong> to set the amount, then <strong>Deliver</strong>.</li>
<li>On the confirm screen, <strong>tap 1 → 2 → 3 in order</strong> (like unlocking a t:slim). A wrong tap resets.</li>
<li>Completing the sequence sends the request to the phone, which carries it out. The remote never delivers on its own, and the pump still enforces its max and signature.</li>
</ol>

## BG complication

The app publishes a **public BG complication** (value + a trend arrow, no units) that Garmin
**Face It** faces and Connect IQ faces can show on your watch face. A reading older than 6
minutes shows `--`. It refreshes while the app is open and via a background refresh (~5 min);
fresh data needs the iPhone app open and connected.

<figure class="cx2-shot watch" markdown="span">
  ![Garmin BG complication](../assets/screenshots/garmin-complication.svg)
  <figcaption>The BG complication on a Face It / CIQ watch face</figcaption>
</figure>

!!! note "Stock Garmin faces can't show it"
    Third-party complication data only appears on **Face It** faces or CIQ faces that support
    complications. Pick one of those and add the *faBolus BG* field.

## The contract

The Monkey C side generates and validates against the same
[`schema/command.schema.json`](../architecture.md#the-command-contract) as the Swift side — the
shared schema is what keeps the two repos in lockstep.

!!! note "Standalone Garmin (no phone) is a separate future project"
    Running the pump protocol **directly on Garmin** (no phone) would need a full Monkey C
    reimplementation of the protocol, crypto, and Bluetooth — gated on whether Connect IQ's
    Bluetooth can establish the bonded/authenticated connection the pump requires.
