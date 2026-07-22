# Settings & options

faBolus has a dedicated **Settings** tab (the app is organized as **Dashboard · Bolus · Alerts ·
Settings**). This page covers everything you can adjust; most settings are shared with the Apple
Watch and Garmin remotes so all three behave consistently.

<div class="cx2-shots" markdown>
<figure class="cx2-shot phone" markdown="span">
  ![Tab bar](../assets/screenshots/tabbar.svg)
  <figcaption>Dashboard · Bolus · Alerts · Settings</figcaption>
</figure>
<figure class="cx2-shot phone" markdown="span">
  ![Settings tab](../assets/screenshots/settings-tab.svg)
  <figcaption>The Settings tab</figcaption>
</figure>
</div>

## Bolus defaults & increments

- **Phone default mode** — open the bolus screen on the phone in **Carbs** or **Units**.
- **Watch/Garmin default mode** — the same choice for the remotes, set independently of the phone
  (previously a single shared setting).
- **Unit increment** — the step size for the units stepper (e.g. 0.01 / 0.05 / 0.1 / 0.5 / 1 / 2 U).
- **Carb increment** — the step size for carb entry (e.g. 1 / 5 / 10 / 15 g).
- **Watch & Garmin increments** — a separate set applied on the remotes, so the wrist can use
  bigger steps than the phone.

The remote defaults and increments propagate to the Apple Watch and Garmin.

## Dashboard chart

<figure class="cx2-shot phone" markdown="span">
  ![Chart with IOB overlay and bolus bars](../assets/screenshots/chart-overlay.svg)
  <figcaption>Glucose with an IOB overlay and bolus bars</figcaption>
</figure>

- **Time window** — 3 / 6 / 12 / 24 h.
- **IOB overlay** — a second axis showing insulin-on-board over time (toggleable).
- **Bolus bars** — vertical bars at each bolus, height ∝ units (toggleable).

Both axes can be turned on/off independently.

## Connecting & pairing

The **Connect** control adapts to your state — first-time pairing (enter the 6-digit code),
**Connect (saved pairing)** to reconnect with no code, and **Re-pair with new code** after a pump
reset. The app auto-reconnects to a saved pump and uses iOS state restoration in the background.
See [Pairing](../setup/pairing.md).

## Pump clock (Tandem Mobi only)

!!! note "Mobi only"
    This section appears **only on Tandem Mobi**. The t:slim X2 does not accept a time write from
    faBolus, so the feature is hidden there.

Under **Settings → Pump → Pump clock**:

- **Keep pump clock synced to phone** (default **on**) — keeps the Mobi's clock matched to the phone.
  It writes the time **at most once a day**, and **immediately** on a time-zone or clock change.
- **Sync pump time now** — a button to push the phone's current time to the pump on demand.

## Activity & sleep automation

Under **Settings → Pump → Activity & sleep automation** — switch the pump into **Exercise** mode on a
workout and **Sleep** mode when the iPhone enters Sleep Focus, via Apple Shortcuts automations. All
**off by default**; auto-switching is **Mobi only** (t:slim gets an optional reminder). See
[Activity & sleep automation](../operate/activity-sleep-automation.md) for the full setup.

## Garmin remote

**Settings → Garmin remote → Screen order** lets you drag to reorder the Garmin screens (Glance /
Alerts / History / Details) and pick which opens first. The layout is pushed to the watch and
remembered there. See [Garmin remote](../remotes/garmin.md).

## Siri & Shortcuts

The Settings tab lists the read-only **Siri** phrases for reference. Full details, plus the
value-returning **Shortcuts** actions you can use in automations, are on
[Siri & Shortcuts](shortcuts.md).

## CGM failover

Under **Settings → Glucose failover** you can choose an optional independent CGM source used as a
backup when the pump's glucose goes stale, and — for the cloud sources — enter your account under
**CGM account credentials**. The pump stays the primary source. See
[CGM failover](../operate/cgm-failover.md) for what each sensor supports and how to set it up.
Changing the source or credentials takes effect after you reopen the app.

## Safety behaviors you can rely on (not configurable)

Always on by design:

- A CGM reading older than **6 minutes** is treated as stale — shown greyed with its age on the
  phone and watches, and reported as not-current by the widgets and Siri. It's never presented as
  the live value.
- Every bolus needs an **explicit confirmation**; remote requests are confirmed deliberately, and
  the **Quick Bolus** widget requires a 1-2-3 tap.
- Every insulin-affecting command is **cryptographically signed** — the pump rejects anything
  that isn't.
- There is **no voice/automated bolus** — Siri is read-only.
