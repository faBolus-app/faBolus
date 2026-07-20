# Safety

!!! warning "Experimental software — you assume all responsibility"
    faBolus is an independent, open-source project **in development for experimental use**. It can
    command an insulin pump to deliver insulin, and it is **not FDA-cleared or otherwise approved**.
    It is provided as-is, with no warranty; if you build, install, or use it, **you take full
    responsibility** for what it does. Work with your own clinician and use your own judgment.

## How faBolus is built for safety

Several checks are built in so a bolus can't happen by accident:

<div class="grid cards" markdown>

-   :material-numeric:{ .lg .middle } **Max-units clamp**

    ---

    Every bolus is capped at your pump's configured maximum, and the pump enforces its own limit
    independently.

-   :material-gesture-tap-button:{ .lg .middle } **Explicit confirmation**

    ---

    Delivery always requires a deliberate confirmation. Widget and touchscreen-remote boluses use a
    1-2-3 confirm sequence; button-only Garmin devices use a two-different-button hold.

-   :material-shield-lock:{ .lg .middle } **Signed commands**

    ---

    Every insulin-affecting command is cryptographically signed; the pump rejects anything that
    isn't. faBolus never modifies pump firmware — it only speaks the existing Bluetooth protocol.

-   :material-close-octagon:{ .lg .middle } **Cancel any time**

    ---

    A bolus can be cancelled mid-delivery, and faBolus reports the amount actually delivered.

</div>

!!! note "One connection at a time"
    The pump accepts a single control connection, so while faBolus is paired the official Tandem
    app cannot be, and vice versa.

## Validation

Every change that can affect delivery is put through the same checks before it's trusted:

| Check | What it proves |
| --- | --- |
| **Protocol parity** | Outgoing messages byte-match the pumpX2 `cliparser` reference. |
| **Delivery accuracy** | Requested units match the amount actually delivered. |
| **Signature enforcement** | Malformed / incorrectly-signed requests are rejected. |
| **Cancel** | A mid-delivery cancel stops the pump and reports partial delivery. |
| **Interruption** | App kill / Bluetooth drop mid-bolus fails safe. |
| **Connection handoff** | Switching control between apps never leaves an ambiguous state. |
| **Soak** | Multi-hour stability; reconnect after suspend. |

!!! note "Independent project"
    faBolus is not affiliated with, endorsed by, or a product of **Tandem Diabetes Care or
    Dexcom**. See the [FAQ](faq.md).
