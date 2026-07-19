# Safety

!!! danger "Read this first"
    This is experimental software that can command an insulin pump to deliver insulin. Used
    incorrectly, that is dangerous. This project exists only as a **bench proof-of-concept**
    and must never be used to dose a person.

## Non-negotiable ground rules
- **Saline, on the bench, never on a body.** Every test uses a dedicated test pump with a
  saline/water cartridge dispensing into a container on a scale. On-body use is out of scope.
- **The dosing path is unproven.** It is our own reimplementation and is treated as unproven
  until exhaustively validated (oracle parity + gravimetric + cancel + signature + interruption
  tests).
- **One control connection at a time.** While this app is paired, the official Tandem app
  cannot be, and vice versa. Never assume coexistence.
- **The pump firmware is never modified.** We only speak the existing BLE protocol.
- **Pin to a tested firmware.** The protocol can break on a pump firmware update; treat the
  app as disposable against vendor changes.

## Interlocks in the app
- Max-units clamp on every bolus.
- Explicit on-screen confirmation before delivery (a saline reminder in the dialog).
- **Double confirmation** for remote (watch/Garmin) requests: the remote requests, the phone
  confirms.
- Working cancel with partial-delivery reporting.
- Signed bolus commands — the pump rejects anything not correctly HMAC-signed.

## Validation gates (every delivery-touching change)
1. Oracle parity — outgoing messages byte-match the `cliparser` oracle.
2. Gravimetric accuracy — requested units vs delivered saline mass.
3. Signature enforcement — malformed/incorrectly-signed requests are rejected.
4. Cancel — mid-delivery cancel stops the pump; partial delivery reported.
5. Interruption — app kill / BLE drop mid-bolus fails safe.
6. Exclusive-connection handoff — official-app ↔ our-app never leaves an ambiguous state.
7. Soak — multi-hour stability; reconnect after suspend.
