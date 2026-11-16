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
- Settings → Bolus & entry → Auto-accept corrections (off by default) answers the calculator's correction
  question yes: the phone's bolus screen chooses the corrected dose (both still show), and the watch and the
  Live Activity skip the question. Stale or pump-flagged readings still add no correction, and every other
  prompt and the final confirmation are unchanged. The watch gets it as the config's
  `bolus.autoAcceptCorrection`, written only when on.

### Changed

- Every glucose plot (the dashboard chart, the widgets, the Live Activity and the watch) draws in the plot
  range from Settings, and in one plot style, Dots or Line (Settings → Display & chart; Dots by default, so
  the widgets and the Live Activity, which drew a line, now draw dots). A reading above the ceiling or
  below the floor is drawn at that edge, so it can't pass for a reading at the edge: a hollow ring among
  dots, a dotted run in a line. A line doesn't join readings more than 15 minutes apart. The chart's
  readout says each reading's own value. The Live Activity and the widgets used a fixed range before.
- The widgets' and Live Activity's small charts colour the line by zone, without the green band, and the
  Live Activity's curve fades behind the glucose and the corner text.
- The Chips style shows every chosen field; it hid the ones the Curve style's corner shows.
- The Live Activity's chart spans are 3, 6 and 8 hours (were 1 to 6); a saved span becomes the nearest.

### Removed

- The Live Activity's Bolus button that only opened the app.

### Fixed

- A bolus record that couldn't be read at launch is no longer overwritten when a watch request is refused or
  a watch cancel is recorded. It was replaced by an empty record, so the next launch forgot any unknown
  bolus it held and stopped blocking new boluses. Only "I checked the pump" writes over it.
- A second Live Activity no longer appears beside one iOS ended. iOS ends a Live Activity after 8 hours but
  leaves it frozen on the Lock Screen for up to 4 more, and opening the app then started a new one beside
  it. Now any card iOS still lists is ended before a new one starts, an extra card is ended on the next
  update, switching the Live Activity off removes an ended card too, and while the app is open a card is
  replaced before it reaches 8 hours.
- A bolus record that couldn't be read at launch (a launch before the first unlock) is read again once it
  can be, and its unknown boluses then show and block as usual. "I checked the pump" confirms only the
  boluses you were shown, and the "can't read" banner has its own "I checked the pump" for a record that
  stays unreadable.
- A pump history record from before a bolus was accepted no longer settles that bolus.
- Cancelling no longer says a bolus "may have finished" when the pump refused to cancel a bolus that had
  already ended while another went on, and a bolus you confirmed on the pump is no longer cancelled by its
  old ID.
- A dose stopped before it was sent to the pump no longer makes the same dose look like a duplicate.
- A bolus you confirmed on the pump is no longer searched for in the pump's history after every
  connection: history the phone already holds settles it first, and the pump is searched a few times at
  most.
- A history search asked for while another runs is no longer dropped, a history page cut short no longer
  ends a search early, and a gap in what arrived never counts as proof a bolus didn't happen.
- A history sync the pump answered with no records no longer counts as synced: it's tried again a few times,
  then left for the next routine sync.
- A dose whose pump bolus limits couldn't be checked (the calculator snapshot couldn't be read again for
  it) now asks you to go on knowing that, on the phone, the Live Activity and the watch, instead of going
  without a word. It's its own question: going on past the max hourly bolus doesn't answer it.
- A CGM reading dated ahead of the phone's clock, from the pump or a backup CGM, no longer stays current
  longer than it should: it ages from when it arrived when that was earlier. One backup reading dated far in
  the future no longer hides the readings after it, nor holds off the urgent-low alarm.
- A dose is recorded with the reading it was corrected from when the reading moved without changing the
  dose.
- A phone clock set while a dose's pump reads wait no longer lets a reading from before them count as read
  for the dose.
- The calculator snapshot is read once after each new CGM reading, so the reading a correction comes from
  is the new one within seconds rather than up to a minute later.
- After a bolus from the phone, the bolus screen is ready for the next one, without a relaunch, and no
  longer fills in a correction on its own; a result that needs attention stays until you tap OK.
- On the Live Activity, Cancel can be tapped again after a cancel the pump didn't confirm, the next bolus
  shows Cancel instead of a stuck "Cancelling", a second tap joins the cancel already going instead of
  starting another, and a cancel's retry never stops a newer bolus.
- The Live Activity no longer stays on "Delivering…" after a short bolus has finished.
- With the app suspended, the Lock Screen marks active insulin, reservoir and the pump link stale on time,
  even when glucose was already stale.
- The G7 grace time left stays right after the phone's clock is set, and is asked for again when its read
  is lost or the link drops.
- A pump notice no longer asks again for a read that is resting after the pump left it unanswered, nor for
  a routine bolus status while a bolus is being followed.
- faBolus no longer sends UserInteraction when the bolus screen opens to a pump suspected of rejecting it,
  whose rejection can drop the link just before a dose.
- Clearing a pump alert from its notification waits for this connection's alert read, not the list the last
  connection left.

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
