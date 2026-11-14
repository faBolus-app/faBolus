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
