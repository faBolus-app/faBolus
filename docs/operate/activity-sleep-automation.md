# Activity & sleep automation

faBolus can switch your pump's **Control-IQ mode** automatically:

- **Exercise mode** when a **workout** starts (and back to normal when it ends).
- **Sleep mode** when your iPhone enters **Sleep Focus** (and back when it ends).

Everything here is **off by default** and opt-in. Auto-switching writes to the pump, so it works on a
**Tandem Mobi only** (with **Advanced control** enabled). A **t:slim X2** can't be switched over
Bluetooth — turn on reminders and faBolus will nudge you to change it on the pump yourself.

!!! warning "Experimental — verify against your care plan"
    Exercise/Sleep modes change Control-IQ's glucose targets. This is experimental and not
    FDA-cleared. Understand what each mode does for your therapy before automating it.

## How it works

Apple's **Shortcuts automations** are the trigger. faBolus exposes two Shortcuts actions —
**Set Exercise Mode** and **Set Sleep Mode** — that you drop into an automation you create once. When
the automation fires, faBolus applies the switch in the background if it's connected to the pump; if
it isn't, the request waits up to 15 minutes for a reconnect, and (if reminders are on) you're
notified.

Turn on the toggles first: **Settings → (pump section) → Activity & sleep automation**.

## Set it up (one time)

iOS won't let an app create a personal automation for you, so build it in the **Shortcuts** app:

**Exercise on workout**

1. **Shortcuts → Automation → +**.
2. Choose **Workout**, pick **Any** (or specific types), **Is Started**, **Run Immediately**.
3. Add action **Set Exercise Mode**, set to **On**.
4. Make a second automation: **Is Ended → Set Exercise Mode = Off**.

**Sleep on Sleep Focus**

1. New automation → **Focus → Sleep → When Turning On → Run Immediately**.
2. Add action **Set Sleep Mode = On**.
3. Second automation: **When Turning Off → Set Sleep Mode = Off**.

This covers both **Apple Watch workouts** (via the Workout automation) and iPhone **Sleep Focus**.

## Garmin

A Garmin can't trigger this automatically: a backgrounded Connect IQ app gets no "activity started"
event, and Garmin doesn't integrate with Apple Shortcuts. Switch modes from the pump, or from
**Pump Control** in faBolus, when you use a Garmin.

## Doing it manually

You can always set the mode by hand in **Settings → Advanced control → Pump Control → Mode**
(Normal / Sleep / Exercise), on a connected Mobi.
