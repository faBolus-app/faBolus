# Pairing your pump

Before the pump accepts any command, it needs an authenticated Bluetooth connection. You do this
once — after that, ControlX2 reconnects on its own using a securely-stored key, no code needed.

<figure class="cx2-shot phone" markdown="span">
  ![Enter the 6-digit pairing code](../assets/screenshots/pairing.svg)
  <figcaption>Enter the pump's pairing code, then Connect</figcaption>
</figure>

!!! warning "Unpair the official app first"
    Only **one** control connection can be active at a time. Remove/close the official Tandem
    **t:connect** app's pairing before pairing ControlX2, and don't expect them to work at once.

!!! danger "Bench pump only"
    Pair only with your **dedicated saline test pump**. See [Safety first](../safety.md).

## Pair (6-digit — most current pumps)

This is the modern scheme (t:slim X2 v7.7+ and Mobi), using a secure JPAKE handshake.

<ol class="cx2-steps">
<li>On the pump: <strong>Options → Device Settings → Bluetooth Settings → Pair Device</strong>. The pump shows a <strong>6-digit</strong> code.</li>
<li>In ControlX2, tap <strong>Connect</strong> and type the 6 digits.</li>
<li>Tap <strong>Connect</strong>. The app scans for the pump, runs the pairing handshake, and derives a signing key.</li>
<li>When the HUD shows <strong>Connected</strong>, you're paired. Live data starts filling in.</li>
</ol>

The app auto-selects the scheme based on the code you enter and the pump's version, so you don't
have to choose.

## Pair (16-character — older t:slim X2, pre-v7.7)

<ol class="cx2-steps">
<li>On the pump: <strong>Options → Device Settings → Bluetooth Settings → Pair Device</strong> to show the <strong>16-character</strong> code.</li>
<li>Enter it in ControlX2 and connect. The app performs the legacy challenge/response handshake.</li>
</ol>

## After pairing

- The pairing is saved **securely in the iOS Keychain**, so future connects use
  **Connect (saved pairing)** — no code required, even after you rebuild the app.
- If you ever reset the pump or it forgets the app, use **Re-pair with new code** from the
  Connect menu to start fresh.
- The signing key authorizes every insulin-affecting command (bolus permission / initiate /
  cancel). The app tracks the pump's clock so those commands are signed with correct timing.

!!! tip "Nothing connecting?"
    Make sure the pump is in pairing mode, Bluetooth permission is granted to ControlX2, and the
    official app isn't holding the connection. More in [Troubleshooting](../troubleshoot.md).

## Under the hood (for the curious)

??? info "What the handshake actually does"
    - **6-digit:** an **EC-JPAKE** handshake (secp256r1 / SHA-256, via mbedTLS in PumpX2Kit) —
      rounds 1–2 plus derive, then Tandem's session-key / key-confirmation rounds 3–4. The
      derived key is `authKey = HKDF(serverNonce, derivedSecret)`, which signs subsequent
      commands.
    - **16-character:** the app sends `CentralChallengeRequest`, receives the pump's HMAC key,
      and replies with a `PumpChallengeRequest` carrying `HMAC-SHA1(pairingCode, hmacKey)`.
