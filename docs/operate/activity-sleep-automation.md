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

## Delay Sleep mode

Want Sleep mode to switch on a little *after* your Sleep Focus starts?

**Option A — short delay (a few minutes)**

1. Automation → **Focus → Sleep → When Turning On → Run Immediately** (turn off *Ask Before Running*).
2. Add **Wait** (Scripting) and set the seconds, e.g. 300 = 5 min.
3. Add **Set Sleep Mode = On**.

iOS pauses the Wait step while your phone is locked, so delays longer than a few minutes may not
fire. Keep this short, or use Option B.

**Option B — fixed-time delay (reliable, recommended for longer delays)**

1. Automation → **Time of Day** → pick the time (e.g. 30 min after your usual bedtime),
   **Repeat Daily**, **Run Immediately** (*Ask Before Running* off).
2. Add **Set Sleep Mode = On**.

This is keyed to the clock, not the moment Sleep Focus starts, but runs reliably overnight. Pair
either option with a matching wake-up automation running **Set Sleep Mode = Off**.

Your Tandem Mobi / Control-IQ has its **own on-pump Sleep schedule**. On **Mobi**, faBolus is its
editor — read and set it from **Pump Control → Sleep schedule** (the Mobi has no on-pump way to
set this). On **t:slim X2**, set it on the pump's own touchscreen; faBolus only displays it here,
read-only. Use the pump's Sleep schedule **or** this Shortcuts automation, not both — running both
can conflict.

## Build a one-tap macro

Combine several faBolus actions into one shortcut and put it on your Home Screen or in the
Shortcuts widget:

1. Shortcuts → **+** (new shortcut).
2. Add **Set Exercise Mode = On**.
3. Add **Set Temp Rate** and choose a percent (0–250%) and duration (15 min–72h) — the same range
   the pump and the official Tandem Mobi app allow. faBolus doesn't narrow this further; your
   pump's own **Basal Limit** (Delivery Limits) is the ceiling, and the pump rejects a rate that
   would exceed it.
4. Name it (e.g. "Going for a run") → **Share → Add to Home Screen**, or add it to the
   **Shortcuts widget** / **Action Button** / **Back Tap**.

Tapping it applies both settings in the background — no confirmation, without opening the app —
as long as you use fixed values and avoid *Ask Each Time* (which pauses to prompt). Temp-rate
options appear only on pumps/controllers that support them. **Boluses are never available in
Shortcuts.**

## Garmin

A Garmin can't trigger this automatically: a backgrounded Connect IQ app gets no "activity started"
event, and Garmin doesn't integrate with Apple Shortcuts. Switch modes from the pump, or from
**Pump Control** in faBolus, when you use a Garmin.

## Doing it manually

You can always set the mode by hand in **Settings → Advanced control → Pump Control → Mode**
(Normal / Sleep / Exercise), on a connected Mobi.
