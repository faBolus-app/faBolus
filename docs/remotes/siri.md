# Siri (read-only)

ControlX2 registers a small set of **read-only** Siri intents (App Intents) so you can ask about
your pump hands-free. They read the latest snapshot the app publishes to the App Group — the same
data the widgets show — so they answer instantly without opening the app or driving Bluetooth.

## Phrases

| Ask | Answers with |
|-----|--------------|
| "Glucose in ControlX2" / "What's my glucose in ControlX2" | latest glucose + trend + age |
| "Insulin on board in ControlX2" | current IOB |
| "Pump status in ControlX2" / "How's my pump in ControlX2" | glucose, IOB, reservoir, battery, connection |
| "Last bolus in ControlX2" | most recent bolus + when |

The exact wording Siri accepts is the app's shortcut phrases (Shortcuts app → ControlX2). You can
also add these to the Shortcuts app or a Home Screen / Lock Screen Shortcut.

## Freshness

- A glucose reading older than **6 minutes** is reported as not recent (never spoken as current).
- If the pump isn't connected, the pump-status answer notes the data may be out of date.
- If the app has never connected, Siri asks you to open ControlX2 and connect first.

## No voice bolus

There is **no Siri bolus intent**, by design. A bolus is a deliberate, confirmed action; the
project only ever allowed voice dosing behind CarPlay's touchscreen confirmation, and CarPlay
isn't available to a pump app (Apple restricts the CarPlay entitlement to specific app
categories). So Siri here is strictly for viewing. Boluses are entered on the phone, Apple Watch,
or Garmin, each with an explicit confirmation. As with everything in this project, any delivery is
**bench-only, saline, never on a body.**
