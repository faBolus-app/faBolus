# Troubleshoot

## Can't find or connect to the pump
- Make sure the **official Tandem app is unpaired/closed** — only one control connection is
  allowed at a time.
- Confirm Bluetooth permission is granted to ControlX2iOS.
- Put the pump in pairing mode; the app scans for the Tandem service (`0000fdfb…`).

## Pairing fails
- Double-check the code type (16-char vs 6-digit) matches your firmware.
- For 6-digit (JPAKE), a wrong code completes the handshake but fails **key confirmation** —
  re-enter the code.

## Bolus rejected
- The command must be correctly HMAC-signed with a recent pump time-since-reset. Reconnect to
  refresh timing.
- Check the max-units clamp.

## Remote (watch/Garmin) request doesn't deliver
- The phone must **explicitly confirm** every remote request (double confirmation).
- If the phone is out of range, the request is queued/failed — reconnect and retry.

## Build issues
- Regenerate the Xcode project: `xcodegen generate`.
- Ensure `PumpX2Kit` and its `vendor/` submodules are checked out
  (`git submodule update --init --recursive`).
