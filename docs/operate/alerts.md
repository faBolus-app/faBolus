# Alerts & alarms

View and clear the pump's active notifications from the phone or the watch — without reaching
for the pump.

## What's shown
The app polls the pump's notification bitmaps every ~60 s:

- **Alerts** — e.g. low insulin, incomplete bolus, low power.
- **Alarms** — more serious, e.g. occlusion, empty cartridge (red).
- **CGM alerts** — high/low/urgent-low, signal loss.
- **Reminders**, and **malfunctions** (view-only — hardware faults can't be cleared remotely).

## Phone
Active notifications appear as a banner on the HUD, most-serious first, each with a **Clear**
button. When connected a small diagnostic line shows the raw pump bitmaps + poll count so you
can confirm the pump is reporting.

## Watch (Garmin)
Swipe up to **Details**, then up again to **Alerts**. Tap a row to clear it; the watch relays
the clear to the phone.

## How clearing works
Clearing sends a **signed `DismissNotificationRequest`** (opcode 184) with the notification's id
+ kind. It's signed like a bolus but does not modify insulin delivery, so it runs under the
`allowNonDelivery` write policy.

!!! warning "Not yet hardware-verified"
    The signed dismiss path is validated by construction (its cargo is asserted byte-for-byte and
    its signing/framing is the same path proven byte-exact for boluses), but clearing has **not
    yet been confirmed on the bench**. Verify it actually dismisses before relying on it.
