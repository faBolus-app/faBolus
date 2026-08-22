---
hide:
  - toc
---

<div class="cx2-hero" markdown>
<span class="cx2-eyebrow">Built by Zev and Tia in tandem</span>

# faBolus — your pump, on your wrist and your phone.

faBolus is a remote for insulin pumps: see your glucose and pump status at a glance, and deliver a
bolus from your **iPhone**, a **Garmin Venu 3S**, or a Home/Lock Screen widget. It supports the
**Tandem t:slim X2** — the Mobi isn't supported in this version.

<span class="cx2-cta" markdown>
[Build it yourself :material-arrow-right:](build/index.md){ .md-button .md-button--primary }
[Read the safety notes](safety.md){ .md-button }
</span>
</div>

!!! warning "Experimental — in development"
    faBolus is an independent, open-source project **in development for experimental use**. It is
    **not FDA-cleared**; if you build and use it, you assume all responsibility. See
    [Safety](safety.md).

## Start here

<div class="grid cards" markdown>

-   :material-shield-check:{ .lg .middle } **Safety**

    ---

    What faBolus is, the interlocks built in, and how to use it responsibly.

    [:octicons-arrow-right-24: Safety notes](safety.md)

-   :material-clipboard-list:{ .lg .middle } **What you'll need**

    ---

    The hardware, accounts, and tools — a pump, an iPhone, a Mac, and a free or paid Apple ID.

    [:octicons-arrow-right-24: Requirements](requirements.md)

-   :material-hammer-wrench:{ .lg .middle } **Build it yourself**

    ---

    A step-by-step, no-experience-required guide: Apple account → Xcode → your iPhone and
    Garmin.

    [:octicons-arrow-right-24: Build guide](build/index.md)

-   :material-tune:{ .lg .middle } **Customize**

    ---

    The in-app **Settings** tab — bolus defaults, chart options, glucose alert thresholds, and more.

    [:octicons-arrow-right-24: Settings](customize/settings.md)

</div>

## What it does

<div class="grid cards" markdown>

-   :material-view-dashboard:{ .lg .middle } **A tabbed, modern app**

    ---

    **Dashboard · Bolus · Alerts · Settings.** The Dashboard shows glucose with a trend and a
    3 / 6 / 12 / 24-hour chart — with an optional **IOB overlay** and **bolus bars** — over a
    details card with everything from the pump (carb ratio, correction factor, target, max
    bolus, reservoir, battery, CGM, last bolus). Every reading shows its **age**, and anything
    older than **6 minutes** is shown greyed — never as the current value.

-   :material-water:{ .lg .middle } **Boluses, with guardrails**

    ---

    Enter units, or enter carbs + BG and let the pump's calculator recommend a dose. Every
    bolus has a max-units clamp and an explicit confirmation, can be **cancelled mid-delivery**,
    and reports the actual amount delivered.

-   :material-watch:{ .lg .middle } **Garmin Venu 3S remote**

    ---

    Request a bolus from your wrist. The remote never touches the pump directly — the iPhone owns
    the connection and confirms every request. The watch gets a glucose complication and a
    history screen.

    [:octicons-arrow-right-24: Garmin remote](remotes/garmin.md)

-   :material-cellphone:{ .lg .middle } **Widgets**

    ---

    Lock/Home Screen widgets for glucose and an overview, plus a **Quick Bolus** widget with a
    1-2-3 confirm you can trigger without opening the app.

    [:octicons-arrow-right-24: iPhone widgets](remotes/iphone-widgets.md)

-   :material-water-outline:{ .lg .middle } **Glucose via Dexcom Share**

    ---

    Glucose normally comes through the pump. **Dexcom Share** is the one optional backup source —
    a cloud-polled feed that keeps a reading flowing if the pump-to-sensor link drops. Stale
    readings are never shown as current. [Learn more](operate/glucose.md).

</div>

## Under the hood

faBolus is built on an open protocol core, and the Garmin watch app lives in its own repository.

| Repository | What it is |
| --- | --- |
| **[TandemKit](https://github.com/faBolus-app/TandemKit)** | The Swift protocol / auth / Bluetooth core: message framing, HMAC signing, pairing, Core Bluetooth. Every outgoing message is tested byte-for-byte against the [pumpX2](https://github.com/jwoglom/pumpx2) `cliparser` oracle. |
| **[faBolus](https://github.com/faBolus-app/faBolus)** | The faBolus iPhone app, iPhone widgets, and the shared phone↔remote command contract. Consumes TandemKit. |
| **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)** | The faBolus Garmin (Connect IQ) watch remote. Pairs to the iPhone app. |

!!! quote "Built on pumpX2 — thank you, James Woglom"
    faBolus stands on the shoulders of **[pumpX2](https://github.com/jwoglom/pumpx2)** by James
    Woglom ([@jwoglom](https://github.com/jwoglom)). His reverse-engineering of the Tandem pump's
    Bluetooth protocol is the foundation of this entire project — `TandemKit` is a Swift port of
    that work, validated byte-for-byte against pumpX2's `cliparser` oracle. **faBolus would not
    exist without it.** The project also draws on the wider
    **[LoopKit](https://github.com/LoopKit)** / **Loop** ecosystem for parts of its visual design
    and documentation. See [NOTICE.md](https://github.com/faBolus-app/faBolus/blob/main/NOTICE.md)
    for full attributions.

!!! note "Independent project"
    faBolus is an independent, open-source project. It is **not affiliated with, endorsed by, or
    a product of Tandem Diabetes Care or Dexcom.** Tandem, t:slim X2, Mobi, and Dexcom are
    trademarks of their respective owners.
