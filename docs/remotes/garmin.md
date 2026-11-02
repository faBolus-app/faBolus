# Garmin watch

The faBolus watch app runs on a **Garmin Venu 3S**. It shows what the phone sends it and can ask the
phone to bolus, cancel or clear an alert. It never talks to the pump: the phone checks every request and
sends the bolus. To install it, see [Garmin watch (build)](../build/garmin-build.md).

## The screens

Swipe up and down to move between them. Choose which appear, their order and the one the app opens on in
**Settings → Watch → Watch layout** on the phone.

| Screen | Shows |
| --- | --- |
| **Glance** | Glucose with its trend and age, and the bolus button |
| **Glucose only** | Glucose, without a bolus button |
| **Clock + glucose** | The time and glucose, without a bolus button |
| **Bolus button only** | Just the bolus button |
| **Alerts** | The pump's open alerts |
| **History plot** | Recent glucose; tap to step through the chart ranges you chose |
| **Details** | Rows you choose, such as active insulin, reservoir, battery and last bolus |

The watch also has a glance in Garmin's glance list, and complications for watch faces that show them:
glucose, and up to three values you choose on the phone. A complication can't show a value's age, so an
old value shows as `--`, never as a number that could pass for current. Arrows are drawn with plain characters (`^ / -> \ v`) so every face's
font can show them.

## Bolus from the watch

Bolusing from the watch is **off** until you turn on **Allow bolusing from the watch** in
**Settings → Watch** on the phone. The phone asks you to confirm each time you turn it on. With
**Read-only (view only)** on, the watch can't bolus at all.

<ol class="cx2-steps">
<li>Tap the bolus button. The screen opens in <strong>Carbs</strong> or <strong>Units</strong>, as set on the phone, and steps by the phone's increments.</li>
<li>Set the carbs or the units. In carbs, the watch shows the dose it works out from the pump's settings as you go.</li>
<li>If the CGM reading is old, the watch asks: <strong>Include reading</strong> or <strong>Carbs only</strong>.</li>
<li>Tap <strong>Deliver</strong>, then tap <strong>1 → 2 → 3</strong> in order. A wrong tap starts over.</li>
</ol>

The phone then checks the request and delivers it, or refuses it and says why. The watch shows the
outcome: **Delivering…**, **Delivered**, **Stopped**, **Pump refused**, **Not delivered** or
**Outcome unknown**.

What the phone checks:

- the request is less than 2 minutes old by the phone's clock, and is acted on at most once, even if the
  watch sends it again;
- for carbs, the phone works the dose out again from the pump's latest values, and refuses it as
  **Dose changed** if it differs from the watch's by more than 0.10 U;
- your remote bolus size limit, if you set one, and the pump's own limits;
- everything the phone's own bolus checks, such as no unknown outcome waiting.

While a bolus delivers, the watch offers **Cancel**. A cancel is never refused.

If the phone isn't reachable, the watch says **Phone not connected. Nothing was sent.** If the phone
doesn't answer after a request went out, it says **No answer from the phone. Check the pump before dosing
again.**

## Alerts on the watch

The watch mirrors the pump alerts the phone shows: the phone is the authority, and the watch shows what
it sends. An alert appears as a card. The watch offers **Clear** only once your pump has accepted a clear
from the phone (see [Alerts](../operate/alerts.md#clearing-an-alert-from-the-phone)); otherwise the card
says to clear it on the pump.

## The phone has to be nearby

The watch reaches the phone through Garmin Connect over Bluetooth, and the phone reaches the pump. If the
phone is out of range, the watch keeps showing the last values with their age, and greys or hides them
as they get old.

## When the versions don't match

The phone and watch apps speak one version of their message format. If they don't match, the watch says
**Update faBolus on phone** or **Update the watch app**, and offers no bolus.
