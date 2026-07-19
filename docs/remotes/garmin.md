# Garmin remote

A Connect IQ (Monkey C) remote companion. Like the Apple Watch, it is a **dumb remote**: it
messages the iPhone host via the **Connect IQ mobile SDK**; the phone runs the confirm
interlock and dispatches through `PumpX2Kit`.

## Use
- A minimal units picker + confirm.
- Requests are subject to the same **double confirmation** on the iPhone.
- Phone-out-of-range fails cleanly.

## Contract
The Monkey C side generates/validates against the same
[`schema/command.schema.json`](../architecture.md) as the Swift side — this shared schema is
the whole reason the Garmin app lives in this repo. Source: `garmin/`.

!!! note "Standalone Garmin is a separate project"
    Running the protocol **standalone on Garmin** (no phone) would require a full Monkey C
    reimplementation of the protocol/crypto/BLE and is tracked as a separate future repo
    (`PumpX2Garmin`), gated on whether Connect IQ's BLE can establish the bonded/authenticated
    connection the pump needs.
