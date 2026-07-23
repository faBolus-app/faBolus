# Eating nudges

**Eating nudges** remind you to bolus when faBolus thinks you're probably eating. It's **advisory
only** — it never doses, never blocks anything, and it's **off by default**. Turn it on under
**Settings → Smart Assist → Eating nudges**.

!!! warning "Advisory, not automatic"
    An eating nudge is just a reminder to open the bolus screen. faBolus never delivers insulin on
    its own. You always decide the dose and confirm it, exactly as usual.

## How it decides

The nudge fuses up to four signals on your phone and only prompts when the combination you chose is
met and stays met for a short **confirmation delay**:

| Signal | Where it comes from |
|---|---|
| **Wrist motion** (p eating) | A small on-device model runs on wrist accelerometer + gyro — from a **Garmin** watch (streamed to the phone) or an **Apple Watch** (on-device). |
| **CGM meal detection** | Your glucose trend, using a port of Loop's unannounced-meal detection — spots a rise that insulin/announced carbs don't explain. |
| **No recent bolus** | Suppresses the nudge if you already bolused in the last *N* minutes (you've covered it). |
| **Location** (optional) | On-device only — skips nudges when you're clearly not at a place you usually eat. |

### Modes

Pick how the wrist and CGM signals combine (**Settings → Eating nudges → Mode**):

- **CGM finds meal, wrist confirms** *(default, battery-smart)* — the CGM (already running, no extra
  battery) spots a likely meal, then the wrist sensor turns on briefly to confirm. Fewest false
  alerts and lowest battery, but a **later** nudge — more of a "you ate and haven't bolused" catch
  than an early pre-bolus prompt.
- **Wrist + CGM (both, always on)** — both must agree, wrist sensing runs continuously. Early and
  precise, but the highest battery use.
- **Wrist or CGM (either)** — nudges as soon as either thinks you're eating. Earliest and most
  sensitive, but the most false alerts.
- **Wrist only** / **CGM only** — a single signal.

### Tuning the trade-off

The settings screen shows a live, **approximate** estimate for your current choices:

- **≈ false alerts per day** (with a Low / Medium / High band),
- **≈ % of meals caught**,
- **≈ time-to-alert** (how soon after eating starts), and
- **battery impact**.

Two sensitivity sliders (**wrist** and **CGM**) and the **confirmation delay** let you trade
sensitivity for fewer false alerts. A longer delay = more confident / fewer false alerts, but a
**later** nudge (less useful for pre-bolusing). The wrist accuracy/false-alert figures come from the
model's own training assessment, so the guidance reflects the real model, not a guess.

## Which watch?

- **Garmin** — the watch streams short motion windows to your phone, which runs the model. Works
  today on a free Apple account. See [Add a Garmin](../build/garmin-build.md).
- **Apple Watch (on-device)** — the watch runs the model itself and relays the result to the phone.
  This path needs the **paid** Apple Developer Program (HealthKit + a workout session keep the
  sensors alive), so it's **off unless you build with `FABOLUS_ONWATCH_EATING=1`**. On a free
  account it's automatically excluded and everything else still builds. See
  [Add the Apple Watch](../build/apple-watch-build.md).

Either way, the phone owns the decision and the nudge — so the CGM signal and the gates work even
without any watch.

## Location (optional)

Turn on **Only at meal places (location)** to have faBolus learn — **entirely on your device** — the
coarse places where you eat, and skip nudges when you're clearly somewhere else. It:

- uses low-power **significant-location** updates (not continuous GPS),
- learns a place when you act on a nudge / bolus for a meal,
- **never gates** until it has learned a few places (so it won't block early nudges), and
- stores only coarse, rounded coordinates locally — nothing leaves your phone.

It's off by default and asks for "When In Use" location permission only when you enable it.

## Learning from your feedback (on-device)

With **Learn from my feedback** on (the default), the nudge adapts to you — all on-device:

- **Tapping the nudge** ("yes, I'm eating") opens the bolus screen and counts as a real meal.
- **Dismissing it** (✕) counts as a false alert.
- **Pre-bolusing** — if you bolus and then the model recognizes eating shortly after, faBolus records
  that as a real meal **silently** (no nudge, since you already dosed). So pre-bolused meals still
  teach the detector, even though you were never prompted.

Over time this **raises the wrist threshold** for people who get false alerts (fewer interruptions),
and — when the bundled model supports on-device updates — **fine-tunes the model** to your own motion.
The settings screen shows how many meals you've confirmed and how many false alerts you've cleared,
and a **Reset personalization** button wipes it. A separate alarm-fatigue layer also rate-limits
repeat nudges and respects quiet hours.

## Privacy & safety

- Everything runs **on-device** — motion, CGM math, location, and personalization. No eating data is
  uploaded.
- The nudge is **advisory**: it can only remind you and open the bolus screen. It never doses.
- It respects **read-only / child mode** — no nudge opens the bolus screen when bolusing is locked.
- The bundled eating model is **preliminary**; treat the wrist signal as a helpful hint, not a
  measurement, and always sanity-check against how you actually feel and your CGM.
