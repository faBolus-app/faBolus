# Changelog

Notable changes to faBolus. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the version in `Config.xcconfig` follows [Semantic Versioning](https://semver.org/).

faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It is for
experimental and demonstration use.

## [Unreleased]

### Added

- Bolus from the Live Activity, off until allowed in Settings → Live Activity: the watch's steps (the
  amount with − and +, the calculator's questions, a review, 1 → 2 → 3, the pump's confirmations, the
  result with Cancel), checked by the phone as a remote's request. iOS asks for an unlock first. Works on
  the Lock Screen, in the Dynamic Island and from the Mac's menu bar; CarPlay and the Apple Watch show it
  without buttons.
- The Live Activity shows the open pump alerts and clears one on the pump where the watch could, cancels a
  bolus from any source, cycles its chart span, and has a Last bolus field, a Slim style, and a choice of
  what the Dynamic Island and the Mac's menu bar show beside the glucose.

- CarPlay and the Apple Watch's Smart Stack show the recent curve under the glucose.

### Changed

- Every glucose plot (the dashboard chart, the widgets, the Live Activity and the watch) draws in the plot
  range from Settings, and leaves out a reading above its ceiling or below its floor instead of drawing it
  on the edge. The Live Activity and the widgets used a fixed range before.
- The widgets' and Live Activity's small charts colour the line by zone, without the green band, and the
  Live Activity's curve fades behind the glucose and the corner text.
- The Chips style shows every chosen field; it hid the ones the Curve style's corner shows.
- The Live Activity's chart spans are 3, 6 and 8 hours (were 1 to 6); a saved span becomes the nearest.

### Removed

- The Live Activity's Bolus button that only opened the app.

### Fixed

#### Phone app

- After a bolus from the phone, the bolus screen is ready for the next one and no longer fills in a
  correction on its own; a result that needs attention stays until you tap OK.
- On the Live Activity, Cancel can be tapped again after a cancel the pump didn't confirm, and the next
  bolus shows Cancel instead of a stuck "Cancelling".
- The Live Activity no longer stays on "Delivering…" after a short bolus has finished.
- With the app suspended, the Lock Screen marks active insulin, reservoir and the pump link stale on time,
  even when glucose was already stale.
- One CGM reading dated in the future no longer hides the readings after it.
- A backup CGM paused after repeated restarts starts again once the pause ends, and CGM settings shows
  until when it's paused.
- After a launch before the first unlock, boluses are unblocked as soon as you unlock the phone.
- A lost alert-state file no longer leaves old notifications showing, and one that can't be read yet is
  never overwritten.
- Notifications posted before the first unlock aren't posted again once the phone is unlocked, and a
  pump disconnect from before the unlock is announced on time, not late.
- A backup CGM no longer starts twice when the app opens just as its pause ends.
- Tapping Cancel on the Live Activity again while a cancel is still going joins that cancel instead of
  starting a second one.

#### Pump

- A safety ledger that couldn't be read at launch is read again once it can be, and "I checked the pump"
  no longer confirms outcomes in it you never saw.
- A history record from before a bolus was accepted no longer settles it.
- Cancelling no longer says a bolus "may have finished" when the pump refused a cancel for a bolus that
  had already ended.
- A dose stopped before it was sent no longer makes the same dose look like a duplicate.
- A bolus started on the pump between Review and Deliver stops the dose even if a read came in between.
- A bolus you confirmed on the pump is no longer searched for in history after every connection.
- A link that drops and comes back no longer re-reads settings and history each time.
- The G7 grace time left stays right after the phone's clock is set, and is asked for again after a drop.
- A dose is recorded with the reading it was corrected from.
- A dose on old settings asks before going on, because the max hourly bolus can't be checked.
- A reading dated ahead of the phone's clock, from the pump or a backup CGM, no longer stays current
  longer than it should: it ages from when it arrived if that was earlier.

#### Watch link

- A watch bolus whose request id was already on record now shows what happened to that dose, never "Not
  delivered" for one that went in.
- A damaged copy of a watch bolus request no longer reports "Not delivered" while a good copy of the same
  request is delivered; a good copy that arrives while the damaged one is being answered is delivered
  once, instead of being turned away.
- A watch bolus whose request id was used before and whose record can't be read now shows "Outcome
  unknown" with what to check, instead of waiting until the watch gives up.
- After the phone relaunches, a watch waiting on a bolus gets its outcome at once instead of showing it
  pending while the pump is read.
- Bolus answers no longer wait behind a send stuck from before the phone slept, or from an earlier watch
  connection.
- The watch offers a correction only from the reading the phone will correct from; otherwise it shows
  "Checking CGM state" and doses carbs only.

## [0.4.0] — 2026-11-01

A new app, rebuilt from the ground up. It keeps the earlier app's bundle ID but none of its data. The
last build of the earlier app is tagged `v1-final`.

### Added

- A Live Activity on the Lock Screen and in the Dynamic Island, in two styles, with a choice of fields
  and chart. It greys out as soon as its first value is too old.
- Touch the dashboard chart to read the time, glucose, active insulin and bolus at that moment.
- A backup CGM read directly from a Dexcom G6 or G7 alongside the Dexcom app, besides Dexcom Share, with
  a test button and a session log export.
- One set of freshness windows for glucose and pump status, used by the phone, the watch, the widgets and
  the Live Activity.
- The logbook is kept on the phone and survives restarts, with the pump's own names for Control-IQ's
  rejected auto-boluses and declined corrections, and an optional "Last auto-correction" row.
- Clearing a pump alert from the phone is learned per pump: "Try clearing from phone" until the pump has
  accepted a clear, then "Clear".
- A notification's Clear action works from the Lock Screen even when the app wasn't running.
- Export diagnostics: the pump and watch connection history, the pump's identity, alerts and bolus
  outcomes.

### Changed

- The first launch removes everything the earlier app stored: settings, pump pairing, Dexcom Share login
  and history. Pair the pump again.
- The phone and the watch speak a new message format (protocol version 2), tested against messages the
  phone's own code writes. An earlier watch app shows "Update watch app"; update both together.
- A bolus whose outcome is unknown blocks new boluses across restarts, until pump history settles it or
  you confirm on the pump. It's never called failed unless history shows it didn't happen.
- The pump's own limits govern: the app's 25 U ceiling is gone, and bolusing no longer waits until the
  pump's maximum has been read.
- Confirm reads the pump's bolus settings and active insulin again, and the dose is shown on a last
  sheet, with its notices, before it's sent.
- Notifications are one switch per kind, with fixed urgency.
- Turning on bolusing from the watch asks for confirmation each time.
- The pump library, TandemKit, is fetched by Xcode at its 0.4.0 release; there's no sibling clone.

### Removed

- The Quick Bolus widget: widgets and the Live Activity only show.
- The watch's bolus passcode. The 1 → 2 → 3 confirm, the read-only switch and the phone's checks remain.
- Child mode and the settings lock.
- The watch's analog clock face and complication display setting.
- Snooze and the daily notification budget.
- The Control-IQ zone display, until the value it reads is verified.
- mmol/L: glucose is shown in mg/dL.
- iPad.

## [0.3.0] — 2026-08-19

A tagged build of the earlier app.

## [0.1.0] — 2026-07-20

The first tagged build of the earlier app.

[Unreleased]: https://github.com/faBolus-app/faBolus/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/faBolus-app/faBolus/compare/v1-final...v0.4.0
[0.3.0]: https://github.com/faBolus-app/faBolus/releases/tag/v0.3.0
[0.1.0]: https://github.com/faBolus-app/faBolus/releases/tag/v0.1.0
