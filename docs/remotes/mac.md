# Mac menu-bar remote

A menu-bar-only Mac app that mirrors the phone and lets you bolus from your desktop. **The Mac
never touches the pump** — like the Apple Watch and Garmin, it's a thin remote: PumpX2Kit runs on
the iPhone, and the Mac relays confirmed commands to it. To build it, see
[Build it yourself](../build/index.md) and pick the **faBolusMac** target.

There is **no Dock icon and no window** — everything lives in the menu-bar item (a glucose value in
your menu bar; click it for the popover).

## Connection (Bluetooth, works when the phone is locked)

The Mac connects to the iPhone over **Bluetooth LE**, not Wi-Fi — so it keeps working when the
iPhone is **locked or the app is in the background** (the phone acts as a BLE peripheral under the
same background mode that keeps the pump link alive). The two devices do **not** need to be on the
same Wi-Fi network; they just need to be in Bluetooth range.

To pair:

1. Open **faBolus on the iPhone** at least once so it starts advertising.
2. On the Mac, click the menu-bar item → the **gear** (top-right) → **Connection**.
3. Pick your iPhone under **Available iPhones** and click **Pair**. macOS will ask for **Bluetooth**
   permission the first time — allow it.

The Mac remembers the paired iPhone and reconnects automatically. **Forget this iPhone** clears it.

## The popover

- **Status** — big glucose + trend (greyed with its age when stale), plus pills for IOB, reservoir,
  battery, and last bolus (each can be turned off — see below).
- **Quick bolus** — choose **Carbs** or **Units**, set the amount, tap **Bolus**, then **Deliver**
  to confirm in place. Carbs are converted to a dose by the iPhone's calculator; the pump enforces
  its max and signs delivery. While a bolus is in flight you get a progress row + **Cancel bolus**.
- **Alerts** — active pump alerts, each with **Dismiss** (relayed to the phone's signed clear).
- **Refresh** re-requests a status snapshot; **Quit** exits the app.

## Display customization

Menu-bar item → **gear** → the **Settings** panel. Everything here also drives the widgets where it
applies, and preferences are shared between the app and widgets.

**Menu bar**

- **Color value by glucose range** — tints the menu-bar number red/green/yellow/orange for
  low / in-range / high / urgent-high.
- **Trend arrow**, **Delta from last reading**, **Insulin on board (IOB)**, **“mg/dL” unit label** —
  each appends that piece to the menu-bar value.

**Status details (popover + widgets)**

- Toggle **IOB**, **Reservoir**, **Battery**, and **Last bolus**.
- **Color glucose by range in widgets** — same range coloring, applied to the widgets.

## Widgets

The Mac ships WidgetKit widgets (Notification Center / desktop) that read the last snapshot the app
published — they can't drive Bluetooth themselves, so they show the last value with its age:

- **Glucose** — glucose + trend.
- **Status** — glucose, IOB, reservoir/battery, and a recent sparkline.
- **Quick Bolus** — interactive: set an amount and confirm with a **1-2-3** tap; the app relays it to
  the iPhone (macOS 14+).

## Requirements

macOS 14 or later. Build the **faBolusMac** target signed with your own team so the shared App Group
(used by the widgets) is provisioned.
