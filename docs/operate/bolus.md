# Bolus & cancel

!!! danger "Saline, bench only"
    Confirm the pump is dispensing **saline into a container on a scale** before every bolus.

## Deliver a bolus
1. Tap the **Bolus** droplet in the toolbar (enabled only when connected).
2. Optionally enter **carbs** and **BG** and tap **Calculate recommendation** — the app derives
   recommended units (units-only path is always available as a fallback).
3. Adjust units with the stepper (0.05 U steps). The **max-units clamp** blocks anything over
   the configured ceiling.
4. Tap **Bolus N U** → confirm the saline dialog.

Under the hood (`PumpX2Kit`): `BolusPermissionRequest` → `InitiateBolusRequest` (signed,
insulin-delivery-gated) → status polling. Every outgoing message is byte-exact against the
oracle.

## Cancel
While a bolus is delivering, tap **Cancel**. The app sends `CancelBolusRequest` and reports the
**partial delivered amount**.

## From a remote (double confirmation)
An Apple Watch or Garmin can request a bolus. The phone then shows an explicit confirm dialog;
delivery only happens after the phone user confirms. If the phone is out of range, the remote
shows a clean failure and nothing is delivered. See [Remotes](../remotes/apple-watch.md).
