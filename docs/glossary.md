# Glossary

Plain-language definitions of terms used across faBolus and its docs — for users and for anyone (or any
LLM) reading the code.

## Diabetes / therapy
- **Bolus** — a dose of insulin delivered at once (e.g. for a meal or a correction).
- **Extended / combo bolus** — a bolus split into a part delivered now and the rest over a set duration.
- **Basal** — the slow background insulin the pump delivers continuously (a *temp basal* is a temporary
  change to it).
- **IOB (insulin on board)** — insulin from recent boluses still active in the body; the calculator
  subtracts it so you don't "stack" doses. Shown as "Active Insulin".
- **Carb ratio** — grams of carbohydrate covered by 1 unit of insulin.
- **ISF / correction factor** — how far 1 unit of insulin is expected to lower glucose (mg/dL per unit).
- **Target (BG)** — the glucose value corrections aim for.
- **Correction** — insulin to bring a high glucose down toward target (IOB is subtracted first).
- **CGM** — continuous glucose monitor (e.g. Dexcom, Libre) reporting glucose every few minutes.
- **Control-IQ** — Tandem's automated insulin-adjustment feature that runs **on the pump** (faBolus does
  not automate dosing — it's a manual remote + viewer).
- **TIR (time in range)** — % of readings in 70–180 mg/dL. **GMI** — an estimated A1C from average
  glucose. **CV** — glucose variability (std ÷ mean); ≤ 36% is a common stability target.
- **Stale reading** — a glucose value older than ~6 min; shown greyed with its age, never used as
  current or to auto-fill a correction.

## Devices / roles
- **Host** — the device physically paired to the pump over Bluetooth (normally the iPhone). It owns the
  pump link and is the only thing that dispenses insulin.
- **Remote** — a device that shows status and *requests* actions the host carries out: Apple Watch,
  Garmin, Mac, or a second iPhone. A remote never touches the pump.
- **Failover CGM source** — an independent glucose feed (Dexcom BLE, Nightscout, xDrip, Apple Health…)
  used when the pump's relayed glucose goes stale.
- **Child / locked mode** — a PIN-locked mode limiting what can be done on a child's own phone.

## Security / protocol (developer)
- **JPAKE** — the password-authenticated key exchange used to pair with the pump (a code proves both
  sides without sending it). Also the basis of the one-time-code Mac/phone pairing (`MacPairing`).
- **Sealed transport** — the AES-GCM layer that end-to-end-encrypts every command on the Bluetooth
  remote link (`SealedTransport`).
- **WritePolicy** — the transport interlock (`.readOnly` / `.allowNonDelivery` / `.allowDelivery`) that
  blocks insulin-affecting messages unless explicitly permitted.
- **Oracle** — the reference Java implementation the Swift pump messages are tested byte-exact against
  (in `PumpX2Kit`).
- **RemoteCommand** — the small JSON contract every remote uses to talk to the host
  (`schema/command.schema.json`).
