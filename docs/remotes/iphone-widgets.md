# Widgets and Live Activity

Widgets and the Live Activity show what faBolus last published, with its age. They can't reach the pump
and can't bolus: a tap opens the app.

## Widgets

| Widget | Sizes | Shows |
| --- | --- | --- |
| **Glucose** | Lock Screen (inline, circular, rectangular) and small Home Screen | Glucose and trend, from the pump or the backup CGM, and its age. The rectangular one adds active insulin. |
| **Pump overview** | Medium Home Screen | Glucose, active insulin, reservoir and battery. |

To add one, touch and hold the Home Screen or Lock Screen, tap **Edit** (or **Customize** on the Lock
Screen), then **Add Widget**, and choose **faBolus**.

Widgets age their values on their own, with the same [freshness windows](../customize/settings.md#freshness)
as the app: an old glucose is greyed and then hidden, and old pump values show as "—". If faBolus stops
publishing for about 6 minutes, they show that no pump is connected.

## Live Activity

Glucose on the Lock Screen and in the Dynamic Island while faBolus runs.

<figure class="cx2-shot phone" markdown="span">
  ![Live Activity settings](../assets/screenshots/live-activity-settings.png)
  <figcaption>Settings → Live Activity</figcaption>
</figure>

Turn it on in **Settings → Live Activity**. It starts the next time you open the app. There you choose:

- **Style**: **Curve** (a full-width glucose curve, with a value of your choice in the top right) or
  **Number and chips**.
- **Chart span**: 1 to 6 hours.
- **Fields**: what it shows, in order, from glucose, active insulin, reservoir, battery, basal,
  Control-IQ, last auto-correction, pump connection (shown when it's down), 30-minute change and time in
  range. The Dynamic Island shows the first ones that fit.
- **Chart**: axis lines, ticks, and the 70 and 180 mg/dL range lines.
- **Bolus button**: opens the app's Bolus screen. Nothing is sent from the Live Activity.

It updates with each new glucose, and with other values at most once a minute. If updates stop, for
example because faBolus was closed, it greys out as soon as its first value is too old, and old values
show as "—" rather than their last reading.
