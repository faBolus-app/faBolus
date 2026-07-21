---
hide:
  - toc
---

<div class="cx2-hero" markdown>
<span class="cx2-eyebrow">Built by Zev and Tia in tandem</span>

# faBolus — your pump, on your wrist and your phone.

faBolus is a remote for insulin pumps: see your glucose and pump status at a glance, and deliver a
bolus from your iPhone, Apple Watch, or Garmin device — a watch or a cycling computer. It currently
supports the **Tandem t:slim X2 / Mobi** pump, and the **Garmin Venu 3S** is the tested Garmin
device.

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

    A step-by-step, no-experience-required guide: Apple account → Xcode → your iPhone, Apple
    Watch, and Garmin.

    [:octicons-arrow-right-24: Build guide](build/index.md)

-   :material-tune:{ .lg .middle } **Customize**

    ---

    The in-app **Settings** tab, plus **Siri** and **Apple Shortcuts**, so it fits how you
    already use your phone.

    [:octicons-arrow-right-24: Settings & Shortcuts](customize/settings.md)

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

-   :material-watch:{ .lg .middle } **Apple Watch & Garmin remotes**

    ---

    Request a bolus from your wrist. Remotes never touch the pump — the iPhone owns the
    connection and confirms every request. Both watches get a glucose complication; the Apple
    Watch has a full chart/details/alerts, and the Garmin a history screen.

-   :material-microphone:{ .lg .middle } **Widgets & Siri**

    ---

    Lock/Home Screen widgets (glucose, overview, a bolus shortcut, and a **Quick Bolus** with a
    1-2-3 confirm), plus **read-only Siri** ("what's my glucose in faBolus") and a set of
    Shortcuts data actions.

-   :material-backup-restore:{ .lg .middle } **CGM failover**

    ---

    An optional **independent glucose feed** as a backup, so a reading keeps flowing if the pump,
    phone, or sensor link drops — Dexcom G7 **and G6/G5/ONE** direct over Bluetooth, **xDrip4iOS**
    (universal — via Apple Health or a local App Group), or LibreLinkUp / Dexcom Share / Nightscout /
    Apple Health.
    The pump stays primary; stale readings are never shown as current. [Learn more](operate/cgm-failover.md).

</div>

## Under the hood

faBolus is built on an open protocol core, and the Garmin watch app lives in its own repository.

| Repository | What it is |
| --- | --- |
| **[PumpX2Kit](https://github.com/faBolus-app/PumpX2Kit)** | The Swift protocol / auth / Bluetooth core: message framing, HMAC signing, pairing, Core Bluetooth. Every outgoing message is tested byte-for-byte against the [pumpX2](https://github.com/jwoglom/pumpx2) `cliparser` oracle. |
| **[faBolus](https://github.com/faBolus-app/faBolus)** | The faBolus iPhone app, Apple Watch remote, iPhone widgets, and the shared phone↔remote command contract. Consumes PumpX2Kit. |
| **[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin)** | The faBolus Garmin (Connect IQ) watch remote. Pairs to the iPhone app. |

!!! note "Independent project"
    faBolus is an independent, open-source project. It is **not affiliated with, endorsed by, or
    a product of Tandem Diabetes Care or Dexcom.** Tandem, t:slim X2, Mobi, and Dexcom are
    trademarks of their respective owners.
