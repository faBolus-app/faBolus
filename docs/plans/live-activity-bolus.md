# Live Activity: bolus, alerts and the watch's feature set

Status: proposal, not built. A dose path: it lands only with the owner's OK.

## Goal

Make the glucose Live Activity do what the Garmin watch does, on the Lock Screen, in the Dynamic Island, in
the Mac menu bar (iPhone Live Activities on macOS), and as far as Apple allows in CarPlay and the Apple
Watch Smart Stack:

- bolus from it, with the watch's flow: the amount chosen with − and +, a review, the 1 → 2 → 3 confirm,
  the phone's confirmations answered there, and the result with Cancel;
- show the pump alerts and clear one on the pump, under the rules the watch follows;
- cancel a bolus from any source;
- fill the remaining gaps with the watch's status and chart screens.

The current Bolus pill, which only opens the app, goes away.

## What iOS allows (Apple's docs, checked 2026-11-13)

| Question | Answer | Source |
|---|---|---|
| Where a button's intent runs | A `LiveActivityIntent` runs in the app's process; iOS launches the app in the background if it isn't running. | [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent), [Adding interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) |
| A tap while the phone is locked | Contradictory docs. The interactivity article says buttons do nothing on a locked device until the person unlocks it; the `authenticationPolicy` page says `.alwaysAllowed` runs while locked. `.requiresAuthentication` accepts an unlocked paired device (a Watch on the wrist); `.requiresLocalDeviceAuthentication` needs the iPhone itself unlocked. | [authenticationPolicy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy) |
| A confirmation dialog from a button | Not documented for widgets or Live Activities; reports say `requestConfirmation` is skipped silently there. So every confirmation is a screen of the Live Activity's own, never a system dialog. | [forum thread](https://developer.apple.com/forums/thread/732037) |
| Mac menu bar | Compact views in the menu bar; clicking shows the Lock Screen view. Buttons work: the tap goes to the iPhone, which runs the intent, with extra latency. A tap elsewhere opens iPhone Mirroring. | [Custom views](https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities), [WWDC25 278](https://developer.apple.com/videos/play/wwdc2025/278/) |
| CarPlay | Buttons do nothing in CarPlay, by design (driving). It shows the compact views, or the `.small` layout when declared. | [Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) |
| Apple Watch Smart Stack | Same `.small` family as CarPlay; buttons may work there. No API tells the Watch and CarPlay apart. | [activityFamily](https://developer.apple.com/documentation/widgetkit/activityfamily) |
| Pending state | `invalidatableContent()` marks a control's view as pending until the next update. | [invalidatableContent](https://developer.apple.com/documentation/swiftui/view/invalidatablecontent(_:)) |
| Size | 4 KB of content per update. | [Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) |

Consequences for the design:

- Every step is a button whose intent the app checks against the state it holds. The Live Activity's view
  is only a picture of that state, which may be out of date, so each tap names the screen it was drawn
  from and a tap from an older screen is ignored.
- The `.small` family (CarPlay and the Watch) shows status and an ongoing bolus's progress, with no buttons.
  Bolusing and clearing are on the Lock Screen, the Dynamic Island and the Mac.
- How a locked iPhone behaves is checked on a device with a passcode before anyone relies on it. The
  simulator can't show it.

## Which surface it is

A new `AccessPolicy.Surface.liveActivity`, a remote:

- `remotesReadOnly` makes it read-only, as it does the watch, and so does `phoneReadOnly`: it is drawn on
  the phone's own Lock Screen, so neither switch leaves it open.
- Its own opt-in, `liveActivityBolusEnabled`, off by default, turned on in the Live Activity settings
  behind the same "Allow bolusing" confirm as the watch's.
- Its doses go through `DoseComposer.composeRemote`, as the watch's do: fresh calculator inputs or a
  refusal, the remote size limit, the remote freshness and supersede checks, and the confirmations as a
  refusal the Live Activity answers and sends again.
- Its ledger peer is `liveActivity`, so its entries never mix with the phone's or the watch's.

Why not the phone's surface: the buttons are reached from the Lock Screen and from other devices, away from
the app's screens and the phone's own prompts. The phone's rules (no remote limit, dialogs for each
question) assume someone is looking at the app.

The path is unchanged below the composer: the composed dose goes to `AppModel.deliver`, which is the
phone's path into the durable ledger and `PumpSession`, and on to TandemKit's write grant. No new delivery
path, no new pump message, no wire change for the watch.

## The flow

The flow's state lives in the app, in a `LiveActivityFlow` (PhoneApp), and is drawn by the Live Activity
from a small `LiveActivityPanel` value carried in each update. A new screen gets a new ID; every button
carries the ID of the screen it was on.

### Idle (the card as today, plus a bottom row)

- **Bolus** when the Live Activity may bolus now.
- The reason, greyed, when it can't, in the watch's short words: "Pump not connected", "Bolus in progress",
  "Check last bolus", "Cartridge not ready", "Read-only", "Delivery locked".
- **Cancel** (red) whenever the pump has a bolus going, from any source, as on the watch's main screen.
- No button at all while bolusing from the Live Activity is off.
- The top pump alert, most severe first, with "+2 more"; tapping it opens the alert screen.

### Entry (the watch's entry screen)

- A mode chip, Units or Carbs ("Food" with carbs off on the pump); tapping it switches and starts from 0.
- The value between − and +. The fine step is the phone's increment (0.05 U, 5 g by default). A coarse
  ±1 U / ±10 g pair sits outside, because each tap is a round trip to the app and the watch's buttons can
  be held. The value stops at 0 and at the lower of the remote limit and the pump's max bolus (25 U when
  neither is known, which isn't a dose limit); carbs stop at 200 g.
- Carbs mode shows the calculator's dose and the watch's message line: "Correction asked next", "No CGM:
  carbs only", "Stale CGM: carbs only", "Waiting for pump settings", the CGM caution, and the calculator's
  low-glucose and IOB messages.
- **Review**, enabled once there is a dose; **✕** closes.

### Correction question (carbs mode, as the watch asks it)

From a current reading of 70 mg/dL or more, when correcting changes the dose: "BG 180 mg/dL, above target
110: add a correction?", with two buttons naming the whole dose each gives ("Corrected 2.35 U", "Carbs only
2.00 U"). Below target it asks whether to reduce. Carbs only is sent as `declineCorrection`.

### Stale reading question (carbs mode, as the watch asks it)

With no current reading but one the composer may include (no older than the includable limit, inside
20–600 mg/dL, not one the pump cautions against), and including it changes the dose: "BG 142 mg/dL, stale
CGM, 9 min ago: include it?", with "Include 2.35 U" and "Carbs only 2.00 U". Include sends
`includeStaleGlucose` with the reading's value, which the composer uses only if it is still the reading it
would include. Otherwise the dose is carbs only, and the screen says "Stale CGM: carbs only" or "No CGM:
carbs only". Nothing ever fills a stale reading in by itself.

### Review and the 1 → 2 → 3 confirm

- The dose, large, and for a calculator dose the watch's split line ("2.00 food + 0.35 correction").
- Three circles, 1, 2 and 3, tapped in order; each turns green. A tap out of order starts the count again.
  The third sends.
- The review expires after 90 s (the composer refuses a request over 120 s old), with a countdown. An
  expired review says "Expired: start over".
- The request's time is when the review appeared, so a bolus from anywhere after that refuses it.

### The phone's confirmations

When the composer answers that the dose needs confirming (too many boluses, the max hourly bolus, low
insulin), the Live Activity shows "Confirm", the phone's text and **Go on: 2.35 U**. Go on doesn't send: it
returns to the 1 → 2 → 3 confirm with that confirmation recorded, and the third tap sends a new request
that carries it. Every confirmation the phone or the watch asks is asked here.

### Result

The watch's headlines: "Sending…", "Starting…", "Delivering…", "Delivered" (green), "Stopped" (orange),
"Pump refused" (red), "Not delivered" (red), "Outcome unknown" (yellow), with "2.35 U delivered" or the
phone's reason under it.

- **Cancel** while it may still be delivering; "Cancelling" after it; after 5 s with no answer, "No answer
  yet. To stop it now, use the pump." A cancel that the pump doesn't confirm is tried again, as the watch
  host does.
- **Done** once settled. A delivered result clears itself after 60 s.
- An unknown outcome says "Check the pump before dosing again." The ledger then blocks every surface until
  pump history settles it or the user confirms on the pump; the idle row shows "Check last bolus".

### Failures

- Refused by the composer or the session: "Not delivered" with the reason, nothing sent. Nothing is retried
  by itself.
- A tap from an older screen, or one that reaches a relaunched app that never drew it: ignored, and the Live
  Activity is redrawn from the app's state, with "That screen had expired. Nothing was sent." where a send
  was asked.
- The app killed mid-delivery: the ledger already records the request before anything is sent, so a
  relaunch finds it in flight or unknown and blocks; the Live Activity shows that from the ledger.

## Pump alerts

From `AlertSnapshot.active`, as the watch gets them: most severe first, red for critical, amber otherwise.

- The idle row shows the top one; the alert screen shows one at a time, title and body, with **Next** when
  there are more.
- **Clear on pump** appears only where the watch offers it: the session says it can be cleared remotely,
  and it isn't a malfunction. It goes through `PumpSession.dismiss`, the same call the watch host makes. The
  watch's notes for the result: "Clearing…", "Pump didn't clear it", "Clear it on the pump", "No answer from
  pump". A cleared alert is hidden for 60 s, until the pump's list catches up.
- The Live Activity doesn't alert by itself: the phone's notifications already do.

## The rest of the watch's features

- **Last bolus** becomes a Live Activity field, which the watch's details show.
- **Alerts count** shows on the idle row.
- **Chart span** cycles 1 → 2 → 3 → 4 → 6 h from a small chart-icon button on the card's bottom row, as
  the watch's chart cycles its ranges. The Slim style has no chart, so no button.
- The rest is already there (glucose colours and staleness, IOB, reservoir, battery, basal, Control-IQ,
  last auto-correction, connection, the curve), or is the lock screen's own (the clock). The calculator
  settings rows (carb ratio, ISF, target, max bolus) stay in the app.
- **`.small`** (CarPlay and the Watch): glucose and trend, the top alert's title, and an ongoing bolus's
  headline. No buttons.

## The Mac menu bar, the Dynamic Island and the Slim style

- **The pill.** The Mac's menu bar shows the compact views side by side, the same ones as the Dynamic
  Island (iOS can't tell the two apart). The leading view is the glucose in its range colour, with ⚠ while
  a pump alert is open. The trailing one is the user's choice: the trend arrow (the default), the 30-minute
  change, or the active insulin. While a Live Activity bolus is going or has just finished, it shows that
  instead, an icon for where it stands before a few words: a drop and "2.00 U" while it delivers, a
  check and "0.95 U" once delivered, a warning and "Check" for an unknown outcome. Stale values grey and drop the arrow, as on the card.
- **Hiding the iPhone's card while keeping the Mac's.** Not possible: the Lock Screen card and the one the
  Mac opens are the same `.medium` view, and CarPlay and the Watch use the separate `.small` one. What is
  offered instead is a **Slim** style, one short row (glucose, age, two fields, the bolus and alert row),
  on both. A bolus or alert screen still opens full size. iOS's own switch (Settings → Face ID & Passcode →
  Allow Access When Locked → Live Activities) hides Live Activities on the locked Lock Screen; whether the
  Mac still shows them then is to be checked on a device.

## The Dynamic Island

Its expanded bottom is too short for the bolus screens. While one is open it shows where the bolus stands
in one row: a result with its Cancel or Done, an alert's title, or "Bolus open on the Lock Screen" with ✕.
The bolus itself is chosen and confirmed on the Lock Screen card, or the Mac's.

## Notifications

The Live Activity never alerts by itself: its updates carry no alert configuration, so a pump alert sounds
once, as the phone's notification. Clear on pump goes through the same session call as the app, so the
alert pipeline withdraws that notification once the pump's list no longer has the alert. A Live Activity
bolus gets the phone's bolus-result notifications like any other bolus (the owner's choice, 2026-11-13).

## Buttons and authentication

Two intent types, compiled into both the app and the widget extension (an intent type in a Swift package
needs extra registration for the widget to find it):

- `LiveActivityActionIntent`, `.requiresAuthentication`: every bolus step and Clear on pump.
- `LiveActivityStopIntent`, `.alwaysAllowed`: Cancel bolus, ✕, Done, Next alert, the chart span. None of
  these sends insulin; Cancel is never gated anywhere in the app.

Each carries one encoded action and the ID of the screen it was on. `perform()` hands it to the app's
handler and returns when the step is done, through to the session's answer for a send.

## Tests

- `AccessPolicy`: the Live Activity is denied while off or read-only, allowed when on, and the watch's
  opt-in doesn't open it.
- The flow, against the scripted pump in `PhoneAppTests`:
  - a units dose through 1 → 2 → 3 is delivered once, through the ledger;
  - taps out of order, from an older screen, after expiry, or into a relaunched app send nothing;
  - carbs mode asks the correction question, and Carbs only sends no correction;
  - a dose changed by the pump's fresh read is refused;
  - low insulin asks to confirm, and Go on then 1 → 2 → 3 delivers;
  - Cancel while delivering stops it, and an unknown outcome blocks;
  - the remote size limit applies, and disabled or read-only refuse;
  - Clear on pump only for an alert the watch could clear.
- The content with a bolus screen and three alerts stays under 4 KB.
- Snapshots, light and dark, on iPhone 17 at iOS 27.2: idle (Bolus, blocked, Cancel, an alert), each
  entry, question, review (0, 1, 2 taps), confirm, each result, the alert screen, `.small`, and the Live
  Activity settings.

## To check on a device before real use

These can't be shown on a simulator: a tap on a locked iPhone with a passcode, from the Mac menu bar, and
from the Watch Smart Stack.

The app relies on iOS's `.requiresAuthentication` to keep a locked iPhone's Lock Screen from bolusing; it
adds no lock check of its own, so a tap from an unlocked Mac or Watch can bolus while the iPhone is locked
(the owner's choice, 2026-11-13). No device report online confirms how iOS treats that policy for Live
Activity buttons: a default-policy button is reported to run on a locked Lock Screen, and an interactive
widget to ask for an unlock first. Before real use, tap each bolus step on a locked iPhone (after first
unlock, and before it after a restart) and confirm iOS asks for Face ID or the passcode before anything
happens.
