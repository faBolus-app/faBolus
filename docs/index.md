---
hide:
  - toc
---

<div class="cx2-hero" markdown>
<span class="cx2-eyebrow">Built by Zev and Tia in tandem</span>

# faBolus: your pump on your phone and your wrist

faBolus is an iPhone app for the **Tandem t:slim X2**. It shows your glucose and pump status, lets
you bolus from the phone, and puts glucose on your Lock Screen, in widgets and on a **Garmin Venu 3S**
watch, which can also send a bolus through the phone.

<span class="cx2-cta" markdown>
[Build it yourself :material-arrow-right:](build/index.md){ .md-button .md-button--primary }
[Read the safety notes](safety.md){ .md-button }
</span>
</div>

!!! warning "Experimental"
    faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It
    is for experimental and demonstration use. Not medical advice — check every value against your pump
    and your clinician. If you build or use it, you assume all responsibility.

## Start here

<div class="grid cards" markdown>

- :material-shield-check:{ .lg .middle } **Safety**

    ---

    What faBolus is, what it checks before every dose, and what it leaves to your pump.

    [:octicons-arrow-right-24: Safety](safety.md)

- :material-clipboard-list:{ .lg .middle } **What you'll need**

    ---

    A Mac, an iPhone, a t:slim X2 and an Apple account. A Garmin Venu 3S if you want the watch.

    [:octicons-arrow-right-24: Requirements](requirements.md)

- :material-hammer-wrench:{ .lg .middle } **Build it yourself**

    ---

    Step by step, no programming needed: Apple account, Xcode, then the app on your iPhone.

    [:octicons-arrow-right-24: Build guide](build/index.md)

- :material-tune:{ .lg .middle } **Settings**

    ---

    What every setting does: bolus entry, freshness, notifications, the watch and the Live Activity.

    [:octicons-arrow-right-24: Settings](customize/settings.md)

</div>

## What it does

<div class="grid cards" markdown>

- :material-view-dashboard:{ .lg .middle } **Dashboard**

    ---

    Glucose with its trend and age, status pills, and a 3 to 24-hour chart with active insulin and
    boluses. Touch the chart to read the values at any moment. A reading that's too old is greyed and
    never shown as current.

    [:octicons-arrow-right-24: Dashboard](operate/status.md)

- :material-water:{ .lg .middle } **Bolus from the phone**

    ---

    Enter carbs and let the pump's own settings suggest a dose, or enter units. faBolus reads the pump
    again before it sends anything, shows the dose to deliver, and you can cancel while it delivers.

    [:octicons-arrow-right-24: Bolus and cancel](operate/bolus.md)

- :material-watch:{ .lg .middle } **Garmin Venu 3S**

    ---

    Glucose, history and details on your wrist, complications for your watch face, and a bolus with a
    1 → 2 → 3 confirm. The phone checks every request; the watch never talks to the pump.

    [:octicons-arrow-right-24: Garmin watch](remotes/garmin.md)

- :material-cellphone:{ .lg .middle } **Widgets and Live Activity**

    ---

    Glucose on the Lock Screen, the Home Screen and in the Dynamic Island. They show, they don't
    bolus.

    [:octicons-arrow-right-24: Widgets and Live Activity](remotes/iphone-widgets.md)

- :material-water-outline:{ .lg .middle } **Backup glucose**

    ---

    Glucose normally comes through the pump. faBolus can also read Dexcom Share, or a G6 or G7
    directly alongside the Dexcom app, and uses it while the pump's reading is old or missing.

    [:octicons-arrow-right-24: Backup CGM](setup/cgm.md)

- :material-bell:{ .lg .middle } **Alerts**

    ---

    The pump's alerts on the phone and the watch, and notices for what only faBolus can see, such as a
    bolus whose outcome is unknown.

    [:octicons-arrow-right-24: Alerts and notifications](operate/alerts.md)

</div>

## Under the hood

faBolus is three open-source repositories.

| Repository | What it is |
| --- | --- |
| **[faBolus](https://github.com/faBolus-app/faBolus)** | The iPhone app, its widgets and Live Activity, and the message format the watch speaks. |
| **[TandemKit](https://github.com/faBolus-app/TandemKit)** | The Swift library that speaks the pump's Bluetooth protocol: pairing, signing and messages. Every message it builds is tested byte for byte against [pumpX2](https://github.com/jwoglom/pumpx2). The app downloads it for you. |
| **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)** | The Garmin Connect IQ watch app. |

!!! quote "Built on pumpX2: thank you, James Woglom"
    faBolus stands on **[pumpX2](https://github.com/jwoglom/pumpx2)** by James Woglom
    ([@jwoglom](https://github.com/jwoglom)). His reverse-engineering of the Tandem pump's Bluetooth
    protocol is the foundation of this project, and TandemKit is a Swift port of it. faBolus would not
    exist without it. The project also draws on **[LoopKit](https://github.com/LoopKit)** and
    **[Loop](https://github.com/LoopKit/Loop)**: the Dexcom readers come from LoopKit's code, and parts
    of the design and these docs take inspiration from Loop and LoopDocs. See
    [NOTICE.md](https://github.com/faBolus-app/faBolus/blob/main/NOTICE.md) for full attributions.

!!! note "Independent project"
    faBolus is not affiliated with Tandem Diabetes Care or Dexcom. Tandem, t:slim X2, Mobi and Dexcom
    are trademarks of their owners.
