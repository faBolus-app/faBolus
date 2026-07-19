# Pairing

The pump requires an authenticated Bluetooth connection before it accepts any command. Two
schemes exist; the app auto-selects based on the code you enter and the pump's API version.

!!! warning "Exclusive connection"
    Unpair the official Tandem app first. Only one control connection can be active at a time.

## 16-character (legacy t:slim X2, pre-v7.7)
1. On the pump: **Options → Device Settings → Bluetooth Settings → Pair Device** to show the
   16-character code.
2. In ControlX2iOS, choose the pump and enter the code.
3. The app sends `CentralChallengeRequest`, receives the pump's HMAC key, and replies with a
   `PumpChallengeRequest` carrying `HMAC-SHA1(pairingCode, hmacKey)`.

## 6-digit (t:slim X2 v7.7+, Mobi — JPAKE)
1. On the pump, start pairing to show a 6-digit code.
2. Enter it in ControlX2iOS. The app runs an **EC-JPAKE** handshake (secp256r1/SHA-256, via
   mbedTLS in `PumpX2Kit`): rounds 1–2 + derive, then Tandem's session-key/key-confirmation
   rounds 3–4. The derived key signs subsequent commands
   (`authKey = HKDF(serverNonce, derivedSecret)`).

## After pairing
The signing key authorizes every insulin-affecting command (bolus permission/initiate/cancel).
The app records the pump's firmware and time-since-reset for signature timing.
