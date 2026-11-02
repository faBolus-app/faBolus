# Alerts and notifications

Your pump alarms and alerts on its own screen, with or without a phone. faBolus mirrors the pump's alerts
on the phone and the watch as a convenience, and adds its own notices for a few things only it can see.

## The Alerts tab

The **Alerts** tab lists the pump's open alerts and alarms, most serious first, then any of faBolus's own
notices that are showing. If the list is older than your pump-status window, it says when it was read:
check the pump for its current alerts.

## Clearing an alert from the phone

Whether a t:slim acts on a clear sent from a phone isn't known yet for every pump, so faBolus learns it
from your pump:

- **Try clearing from phone** appears while it isn't known for your pump. faBolus sends one clear and
  reads the pump's alerts again. If the alert is gone, your pump clears; from then on its alerts offer
  **Clear**. If the alert is still there, the app says "The pump didn't clear it — clear it on the pump."
- **Clear** appears once your pump has accepted a clear.
- **Clear it on the pump** appears when the phone can't clear this alert.

A clear needs the pump connected. The same choice applies on the watch, except that the watch offers
Clear only once your pump has accepted one.

## Notifications

faBolus asks for permission to notify at first launch. After onboarding, a short note explains what its
notifications are and aren't.

| Notification | When |
| --- | --- |
| **Bolus result** | A bolus finished, stopped, was refused, or its outcome is unknown. Can't be turned off. |
| **Pump disconnected** | The pump stayed out of reach for the delay you choose (immediately up to 30 minutes, or never), with reminders 15 and 30 minutes after the drop. |
| **Connection unstable** | The pump keeps dropping the link. |
| **Urgent low (backup CGM)** | The [backup CGM](../setup/cgm.md) reads an urgent low while the pump's glucose is down. |
| **Pump alerts & alarms** | The pump raised an alarm, alert, reminder or malfunction. |
| **CGM alerts & errors** | The pump raised a CGM alert. |
| **Bolus not delivered** | A bolus couldn't be delivered. |
| **Remote bolus refused** | The phone refused a bolus request from the watch. |

Turn each one on or off in **Settings → Notifications**. All are on by default.

A pump-alert notification has a **Clear** action. From the Lock Screen it clears the alert on the pump,
even if faBolus wasn't running; it waits up to 20 seconds for the pump to connect. If the pump doesn't
clear it, the notification comes back saying to clear it on the pump.

## Focus and Time Sensitive

The bolus result, pump disconnected, connection unstable and the backup urgent low are sent as
**Time Sensitive**, so they can come through a Focus, when the app was built with that capability (a
paid account, see [the build guide](../build/build-app.md#step-4-make-the-xcode-project)). Otherwise
they arrive as normal notifications. faBolus doesn't use Critical Alerts.

If notifications or Time Sensitive notifications are turned off for faBolus in iOS Settings, a banner in
the app says so, with a button to open Settings.
