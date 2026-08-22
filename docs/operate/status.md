# Dashboard & status

The app is organized into four tabs — **Dashboard · Bolus · Alerts · Settings**. The
**Dashboard** is a modern heads-up display; all values update live while you're connected,
and it scrolls to a details card with everything the pump reports.

<figure class="cx2-shot phone" markdown="span">
  ![The Dashboard / status HUD](../assets/screenshots/hud.svg)
  <figcaption>Chart, status ring, and pills at a glance</figcaption>
</figure>

## What's on screen

| Element | Shows |
| --- | --- |
| **Glucose chart** | Recent CGM readings from the pump, with an in-range band (70–180 mg/dL) and range-colored points. Pick the window (3 / 6 / 12 / 24 h), and optionally overlay **IOB** and **bolus bars** — see [Settings](../customize/settings.md#display-chart). |
| **Status ring** | Current glucose + trend, ringed by a color for **connection/activity** (connected, delivering, scanning, disconnected). It is **not** a closed-loop indicator — faBolus never automates dosing. |
| **Active Insulin (IOB)** | Insulin on board. |
| **Reservoir** | Units remaining in the cartridge. |
| **Pump** | Battery %. |
| **CGM** | Sensor status. |
| **Last bolus** | Amount and time of the most recent bolus. |
| **Details card** | Scroll down for carb ratio, correction factor (ISF), target, max bolus, reservoir, battery, CGM status, and last bolus. |

## Connecting

Tap **Connect** (top-left) to scan for and connect to your pump. If a pairing is already saved,
you'll get **Connect (saved pairing)** and **Re-pair with new code** options. The app also
auto-reconnects when you open it or bring it to the foreground. See
[Pairing](../setup/pairing.md).

## Staleness

Every glucose reading shows its **age**. A reading older than **6 minutes** is treated as stale
so it's never mistaken for a current one: on the phone (and the Garmin remote) it's still shown,
just **greyed, with its age called out**; the Quick-Bolus widget greys the number the same way and
drops the trend arrow, then shows "–" once it's past the hide delay you set in Settings. If the
pump's own glucose goes stale and you've turned on [Dexcom Share](glucose.md) as a fallback, an
independent reading fills in until the pump's own feed recovers.

!!! note "Terminology"
    "Active Insulin" (IOB) means insulin on board. faBolus is a manual remote-bolus + status
    viewer, not an automated closed-loop system.

## Statistics card

Turn on **Settings → Display & chart → Show statistics card** to add a collapsible card below the
chart with **Time-in-Range**, a color band breakdown (very-low → very-high), **GMI**, **average**, and
**variability (CV)** over the last ~24 hours held in memory. It's off by default so the dashboard stays
simple; the numbers are computed from the same rolling history the chart uses (not a long-term store).

## Next

- [Deliver a bolus](bolus.md)
- [View and clear alerts](alerts.md)
- [Customize what you see](../customize/settings.md)
