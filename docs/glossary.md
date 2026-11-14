# Glossary

Plain-language definitions of the terms used in faBolus and these docs.

## Diabetes and therapy

- **Bolus**: a dose of insulin given at once, for a meal or a correction.
- **Basal**: the background insulin the pump delivers all the time. A *temporary rate* changes it for a
  while.
- **Active insulin (IOB, insulin on board)**: insulin from recent boluses that's still working. The
  calculator subtracts it, so doses don't stack.
- **Carb ratio**: grams of carbohydrate covered by 1 unit of insulin.
- **Correction factor (ISF)**: how far 1 unit is expected to lower glucose, in mg/dL.
- **Target**: the glucose a correction aims for.
- **Correction**: insulin to bring a high glucose down toward the target, after subtracting active
  insulin.
- **CGM**: continuous glucose monitor, such as a Dexcom G6 or G7, reporting glucose every few minutes.
- **Control-IQ**: Tandem's automated insulin adjustment, which runs on the pump. faBolus doesn't automate
  dosing; it shows Control-IQ's state and history.
- **Time in range (TIR)**: the share of readings between 70 and 180 mg/dL. **GMI**: an estimate of A1C
  from average glucose. **CV**: glucose variability; 36% or less is a common stability target.

## faBolus

- **Stale**: a value older than its freshness window. It's greyed or shown as "—", never as current, and
  a stale glucose never fills a correction.
- **Backup CGM**: a second glucose source (Dexcom Share, or a G6 or G7 read directly), used only while
  the pump's reading is old or missing.
- **Outcome unknown**: faBolus lost track of a bolus after it may have started. New boluses wait until
  pump history settles it or you confirm on the pump.
- **Stopped**: a bolus that delivered less than asked, for example because it was cancelled.
- **Read-only**: a switch that stops the phone, or the watch, from bolusing. Cancel still works.
- **Remote**: something that shows status and asks the phone to act: the Garmin watch, and the Live
  Activity's buttons. The widgets only show.

## Developer

- **JPAKE**: the key exchange used to pair with a 6-digit code: both sides prove they know the code
  without sending it.
- **Signed message**: a command carrying a signature made with the pairing key. The pump refuses an
  unsigned or wrongly signed bolus.
- **pumpX2 / the oracle**: James Woglom's reverse-engineering of the pump protocol. TandemKit's messages
  are tested byte for byte against its Java implementation.
- **Protocol version 2**: the message format between the phone and a remote, defined in faBolus's
  `Packages/RemoteProtocol/contract/`.
