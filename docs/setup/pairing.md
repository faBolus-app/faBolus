# Pairing your pump

Before the pump accepts any command, it needs an authenticated Bluetooth connection. You do this
once — after that, faBolus reconnects on its own using a securely-stored key, no code needed.

<figure class="cx2-shot phone" markdown="span">
  ![Enter the 6-digit pairing code](../assets/screenshots/pairing.svg)
  <figcaption>Enter the pump's pairing code, then Connect</figcaption>
</figure>

!!! warning "Unpair the official app first"
    Only **one** control connection can be active at a time. Remove/close the official Tandem
    **t:connect** app's pairing before pairing faBolus, and don't expect them to work at once.

## Pair your pump

The t:slim X2 uses a secure **JPAKE** handshake, in one of two forms depending on its firmware:
a 6-digit code on v7.7 and later, or an older 16-character code before that. faBolus auto-selects
the right handshake from the code you enter, so you never have to choose a "scheme."

!!! note "Mobi isn't supported yet"
    This build only pairs a t:slim X2. If faBolus detects a Mobi during pairing, it disconnects and
    shows "Tandem Mobi isn't supported in this version of faBolus. This build supports the Tandem
    t:slim X2 only." — support for Mobi is planned for a later release.

### t:slim X2 (v7.7+)

The t:slim X2 has a screen, so it shows a fresh 6-digit code when you start pairing on the pump.

<ol class="cx2-steps">
<li>On the pump: <strong>Options → Device Settings → Bluetooth Settings → Pair Device</strong>. The pump screen shows a <strong>6-digit</strong> code.</li>
<li>In faBolus, tap <strong>Connect</strong> and type those 6 digits.</li>
<li>Tap <strong>Connect</strong>. The app scans for the pump, runs the handshake, and derives a signing key.</li>
<li>When the HUD shows <strong>Connected</strong>, you're paired. Live data starts filling in.</li>
</ol>

### Older t:slim X2 (pre-v7.7 — 16-character)

<ol class="cx2-steps">
<li>On the pump: <strong>Options → Device Settings → Bluetooth Settings → Pair Device</strong> to show the <strong>16-character</strong> code.</li>
<li>Enter it in faBolus and connect. The app performs the legacy challenge/response handshake.</li>
</ol>

<div class="cx2-check" markdown>
**Success looks like:** the top of the app says **Connected**, and your glucose, insulin, and
battery start filling in within a few seconds.
</div>

## After pairing

- The pairing is saved **securely in the iOS Keychain**, so future connects use
  **Connect (saved pairing)** — no code required, even after you rebuild the app.
- If you ever reset the pump or it forgets the app, use **Re-pair with new code** from the
  Connect menu to start fresh.
- The signing key authorizes every insulin-affecting command (bolus permission / initiate /
  cancel). The app tracks the pump's clock so those commands are signed with correct timing.

!!! tip "Nothing connecting?"
    Make sure the pump is in pairing mode, Bluetooth permission is granted to faBolus, and the
    official app isn't holding the connection. More in [Troubleshooting](../troubleshoot.md).

## Using faBolus alongside the official t:connect app

The pump keeps **one** paired controller and issues a **new code** every time you pair — it never
stores two, and the code can't be shared between apps (each derives its own key). So faBolus and the
official **t:connect** app can both be installed, but only one is paired/connected at a time, and
switching is a **full re-pair, not a quick toggle**:

<ol class="cx2-steps">
<li>On the pump, <strong>Pair Device</strong> shows a new code; pair whichever app you want to use.</li>
<li>That <strong>evicts</strong> the other app's pairing — to switch back, you re-pair it with another new code.</li>
</ol>

Day-to-day this is painless if you pick one everyday controller: while faBolus stays paired it
reconnects with **no code**, so the new-code step only appears when you bounce between the two.

!!! note "faBolus doesn't replace the official app"
    Some pump settings and configuration can only be changed in **t:connect**; faBolus doesn't
    support them yet. When you need one, pair t:connect, make the change, then re-pair faBolus for
    monitoring and remote bolus.

## Under the hood (for the curious)

??? info "What the handshake actually does"
    - **6-digit:** an **EC-JPAKE** handshake (secp256r1 / SHA-256, via mbedTLS in TandemKit) —
      rounds 1–2 plus derive, then Tandem's session-key / key-confirmation rounds 3–4. The
      derived key is `authKey = HKDF(serverNonce, derivedSecret)`, which signs subsequent
      commands.
    - **16-character:** the app sends `CentralChallengeRequest`, receives the pump's HMAC key,
      and replies with a `PumpChallengeRequest` carrying `HMAC-SHA1(pairingCode, hmacKey)`.
