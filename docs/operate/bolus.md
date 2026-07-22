# Bolus & cancel

!!! warning "Confirm every bolus"
    faBolus is experimental and not FDA-cleared. Always confirm the amount before you deliver.

<div class="cx2-shots" markdown>
<figure class="cx2-shot phone" markdown="span">
  ![Bolus entry](../assets/screenshots/bolus-entry.svg)
  <figcaption>Enter units, or carbs + BG for a recommendation</figcaption>
</figure>
<figure class="cx2-shot phone" markdown="span">
  ![Bolus confirmation dialog](../assets/screenshots/bolus-confirm.svg)
  <figcaption>Explicit confirm before anything is delivered</figcaption>
</figure>
<figure class="cx2-shot phone" markdown="span">
  ![Delivering with a Cancel button](../assets/screenshots/bolus-delivering.svg)
  <figcaption>Cancel any time while it's delivering</figcaption>
</figure>
</div>

## Deliver a bolus

<ol class="cx2-steps">
<li>Open the <strong>Bolus</strong> tab (enabled only when connected). It opens in your default mode (Carbs or Units) from <a href="../customize/settings/">Settings</a>.</li>
<li>Either enter <strong>units</strong> directly, or enter <strong>carbs</strong> (and optionally <strong>BG</strong>) — the recommendation updates <strong>automatically as you type</strong>, using the pump's own calculator (carb ratio, ISF, target, IOB) to suggest a dose. (There's no separate button to press; tapping anywhere on the carbs/units row focuses the field.)</li>
<li>Adjust units with the stepper (step = your <strong>unit increment</strong> from Settings). The <strong>max-units clamp</strong> blocks anything over your pump's configured ceiling.</li>
<li>Tap <strong>Bolus N U</strong>, then confirm the dialog.</li>
</ol>

## Cancel & partial delivery

While a bolus is delivering, a prominent **Cancel** button is available on the HUD and the bolus
sheet. Tapping it sends a cancel to the pump, and the app reports the **actual amount delivered**
before the stop — so a cancelled bolus tells you exactly how much went through.

## From a remote (double confirmation)

An Apple Watch or Garmin can *request* a bolus, but the phone stays in control:

- **Apple Watch:** the request appears on the phone as a confirm dialog; delivery only happens
  after you confirm on the iPhone.
- **Garmin:** you complete the confirmation on the watch — tap 1-2-3 on a touchscreen, or the
  two-button hold on a button device — and the phone carries it out.
- If the phone is unreachable, the remote shows a clean failure and **nothing is delivered**.

See [Apple Watch](../remotes/apple-watch.md) and [Garmin](../remotes/garmin.md).

## Under the hood (for the curious)

??? info "The signed delivery sequence"
    Via PumpX2Kit: `BolusPermissionRequest` → `InitiateBolusRequest` (signed and
    insulin-delivery-gated) → status polling until the bolus finishes or is cancelled →
    `LastBolusStatus` for the delivered amount. Every outgoing message is asserted byte-exact
    against the pumpX2 `cliparser` oracle.

## Recommendation reasoning

Under the recommended dose there's a collapsible **Show reasoning** breakdown: the **carb + correction**
total and the **active insulin (IOB)** subtracted. Hide the whole breakdown with **Settings → Bolus &
entry → Show recommendation reasoning**. (The enforced pump-max limit still caps the dose — see the
max-units clamp above.)

## Extended (combo) bolus

Turn on **Settings → Bolus & entry → Extended (combo) bolus** to split a dose into a **now** portion
and a portion delivered **over a duration** (e.g. 50% now, the rest over 2 hours). The total must be at
least 0.40 U. It goes through the same confirm + max-bolus clamp + signed path as a standard bolus.
