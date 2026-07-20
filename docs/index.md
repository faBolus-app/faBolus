---
hide:
  - toc
---

<div class="cx2-hero" markdown>
<span class="cx2-eyebrow">Independent · open · bench proof-of-concept</span>

# Your Tandem pump, on your wrist and your phone.

ControlX2iOS is an independent, open reimplementation of a **Tandem t:slim X2 / Mobi** remote:
see your glucose and pump status at a glance, and deliver a **manual bolus** from your iPhone,
Apple Watch, or Garmin watch — all built by you, on your own devices.

<span class="cx2-cta" markdown>
[Build it yourself :material-arrow-right:](build/index.md){ .md-button .md-button--primary }
[Read the safety rules](safety.md){ .md-button }
</span>
</div>

!!! danger "This is a bench proof-of-concept — never for therapy"
    ControlX2iOS can command an insulin pump to deliver insulin. This project exists **only** as
    a bench experiment: every test uses a **dedicated test pump dispensing saline into a
    container on a scale — never on a body.** On-body use is out of scope. The dosing path is
    an independent reimplementation and is treated as **unproven**. Please read
    [Safety first](safety.md) before anything else.

## Start here

<div class="grid cards" markdown>

-   :material-shield-check:{ .lg .middle } **Safety first**

    ---

    The non-negotiable ground rules, the interlocks in the app, and the validation gates.

    [:octicons-arrow-right-24: Safety rules](safety.md)

-   :material-clipboard-list:{ .lg .middle } **What you'll need**

    ---

    The hardware, accounts, and tools — including a saline test pump and a free or paid Apple ID.

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

-   :material-view-dashboard:{ .lg .middle } **A tabbed, Loop-style app**

    ---

    **Dashboard · Bolus · Alerts · Settings.** The Dashboard shows glucose with a trend and a
    3 / 6 / 12 / 24-hour chart — with an optional **IOB overlay** and **bolus bars** — over a
    details card with everything from the pump (carb ratio, correction factor, target, max
    bolus, reservoir, battery, CGM, last bolus). Readings older than **6 minutes** are hidden.

-   :material-water:{ .lg .middle } **Manual boluses, with guardrails**

    ---

    Enter units, or enter carbs + BG and let the pump's calculator recommend a dose. Every
    bolus has a max-units clamp and an explicit confirmation, can be **cancelled mid-delivery**,
    and reports the actual amount delivered.

-   :material-watch:{ .lg .middle } **Apple Watch & Garmin remotes**

    ---

    Request a bolus from your wrist. Remotes never touch the pump — the iPhone owns the
    connection and confirms every request. Both watches get a glucose complication; the Apple
    Watch has a full chart/details/alerts, and the Garmin a Dexcom-style history screen.

-   :material-microphone:{ .lg .middle } **Widgets & Siri**

    ---

    Lock/Home Screen widgets (glucose, overview, a bolus shortcut, and a **Quick Bolus** with a
    1-2-3 confirm), plus **read-only Siri** ("what's my glucose in ControlX2") and a set of
    Shortcuts data actions.

</div>

## The two repositories

This documentation covers the **apps**. They're built on a separate protocol library, and the
Garmin watch app now lives in its own repo.

| Repository | What it is |
| --- | --- |
| **[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit)** | The Swift protocol / auth / Bluetooth core: message framing, HMAC signing, legacy + JPAKE pairing, Core Bluetooth. Every outgoing message is tested byte-for-byte against the [pumpX2](https://github.com/jwoglom/pumpx2) `cliparser` oracle. |
| **[ControlX2iOS](https://github.com/zgranowitz/ControlX2iOS)** | The iPhone app, Apple Watch remote, iPhone widgets, and the shared phone↔remote command contract. Consumes PumpX2Kit. |
| **[PumpX2Garmin](https://github.com/zgranowitz/PumpX2Garmin)** | The Garmin (Connect IQ / Monkey C) watch remote. Pairs to the iPhone app. |

!!! warning "Not affiliated"
    Not affiliated with, endorsed by, or a fork of **Tandem Diabetes Care**, jwoglom's
    `controlX2` / `pumpX2`, or **Loop / LoopKit**. The name mirrors `controlX2` only to signal
    the parallel. The UI borrows Loop's visual language for familiarity only.
