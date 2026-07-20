# Safety first

!!! danger "Read this before you build or connect anything"
    ControlX2iOS is experimental software that can command an insulin pump to deliver insulin.
    Used incorrectly, that is dangerous. It exists **only** as a bench proof-of-concept and must
    **never** be used to dose a person.

## The one rule that matters most

<div class="cx2-hero" markdown>
<span class="cx2-eyebrow">Non-negotiable</span>

### Saline, on the bench, never on a body.

Every test uses a **dedicated test pump** with a saline/water cartridge, dispensing into a
container on a scale. On-body use is out of scope — full stop.
</div>

## Non-negotiable ground rules

<div class="grid cards" markdown>

-   :material-flask:{ .lg .middle } **Saline test pump only**

    ---

    Use a pump you have dedicated to bench testing — never anyone's therapy pump. Saline
    cartridge, dispensing into a container on a scale.

-   :material-alert-decagram:{ .lg .middle } **The dosing path is unproven**

    ---

    It's an independent reimplementation, treated as unproven until it clears every validation
    gate below.

-   :material-link-variant-off:{ .lg .middle } **One connection at a time**

    ---

    While ControlX2 is paired, the official Tandem app cannot be, and vice versa. Never assume
    the two can coexist.

-   :material-lock-check:{ .lg .middle } **Firmware is never modified**

    ---

    The app only speaks the pump's existing Bluetooth protocol. It's pinned to a tested firmware
    and treated as disposable against vendor changes.

</div>

## Interlocks built into the app

- **Max-units clamp** on every bolus (your pump's configured maximum).
- **Explicit on-screen confirmation** before delivery, with a saline reminder in the dialog.
- **Double confirmation** for remote (watch / Garmin) requests — the remote requests, and the
  phone confirms before anything is delivered.
- A working **cancel** with partial-delivery reporting.
- **Signed bolus commands** — the pump rejects anything that isn't correctly HMAC-signed.

## Validation gates

Every change that can touch delivery must clear all of these before it's trusted:

| # | Gate | What it proves |
| --- | --- | --- |
| 1 | **Oracle parity** | Outgoing messages byte-match the pumpX2 `cliparser` oracle. |
| 2 | **Gravimetric accuracy** | Requested units match the delivered saline mass on a scale. |
| 3 | **Signature enforcement** | Malformed / incorrectly-signed requests are rejected. |
| 4 | **Cancel** | A mid-delivery cancel stops the pump; partial delivery is reported. |
| 5 | **Interruption** | App kill / Bluetooth drop mid-bolus fails safe. |
| 6 | **Exclusive-connection handoff** | Official-app ↔ ControlX2 never leaves an ambiguous state. |
| 7 | **Soak** | Multi-hour stability; reconnect after suspend. |

!!! warning "Not affiliated"
    ControlX2iOS is not affiliated with, endorsed by, or a fork of Tandem Diabetes Care,
    jwoglom's `controlX2` / `pumpX2`, or Loop / LoopKit. See the [FAQ](faq.md).
