# Alerts & alarms

View and clear the pump's active notifications from the phone or your watch — without reaching
for the pump. On the phone they live on the **Alerts** tab (and as a banner on the Dashboard).

<figure class="cx2-shot phone" markdown="span">
  ![Alerts on the phone](../assets/screenshots/alerts.svg)
  <figcaption>Active notifications, most-serious first, each with Clear</figcaption>
</figure>

## What's shown

The app polls the pump's notification bitmaps frequently and groups them by severity:

| Type | Examples | Can clear? |
| --- | --- | --- |
| **Alarms** (most serious) | Occlusion, empty cartridge | Yes |
| **Alerts** | Low insulin, incomplete bolus, low power | Yes |
| **CGM alerts** | High / low / urgent-low, signal loss | Yes* |
| **Reminders** | Configured reminders | Yes |
| **Malfunctions** | Hardware faults | View-only |

## On the phone and watch

Notifications appear most-serious first, each with a **Clear** button (a signed dismiss sent to
the pump). On the Apple Watch and Garmin, the **Alerts** screen shows the same list — tap a row to
clear it, and the watch relays the request to the phone. When connected, a small diagnostic line
shows the raw pump bitmaps and poll count so you can confirm the pump is reporting.

## Condition-based (CGM) alerts

Some alerts are **condition-based** — most importantly the CGM **high / low glucose** alerts.
While the reading is genuinely out of range the pump re-raises the alert on every poll, so it
**cannot be cleared on the pump** until glucose returns to range (the official Tandem/Dexcom app
behaves the same way — you can only acknowledge/snooze it). In faBolus, tapping **Clear** on
such an alert **snoozes it on your phone**: it's hidden and stops re-notifying for 30 minutes (or
until the pump condition clears). The Alerts screen says so when a CGM alert is active. The pump's
dismiss acknowledgement shows in the diagnostic line (`ack 0 (accepted)` vs `ack N (rejected)` vs
`no ack`).

## How clearing works

Clearing sends a **signed `DismissNotificationRequest`** with the notification's id and kind. It's
signed like a bolus but does **not** modify insulin delivery, so it runs under a restricted
"non-delivery" write policy.

!!! warning "Clearing isn't hardware-verified yet"
    The dismiss path is validated by construction — its bytes are asserted exactly and it uses the
    same signing/framing proven byte-exact for boluses — but clearing has **not yet been confirmed
    in testing**. Verify it actually dismisses before relying on it.
