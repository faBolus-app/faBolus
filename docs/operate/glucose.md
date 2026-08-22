# Glucose (Dexcom Share)

Glucose normally arrives through the pump — a t:slim X2 paired with a Dexcom sensor relays its own
readings to faBolus. **Dexcom Share** is the one optional, independent source you can add on top of
that: a cloud-polled feed that keeps a reading flowing if the pump-to-sensor link drops, at the cost
of needing a Share account and an internet connection. There's no direct-Bluetooth CGM connection
and no multi-source failover on this version — Share is the only fallback.

## Turning it on

In **Settings → CGM & failover**, pick **Dexcom Share (cloud, last resort)** from the **Failover
CGM** picker, then open **CGM credentials & testing** and enter your Share username, password, and
region. The change takes effect after you reopen the app.

## Staleness

Every reading shows its age. By default, a reading older than **6 minutes** is shown greyed out
instead of as current — you can adjust that window (4 to 20 minutes) under **Glucose staleness** in
the same settings screen. A stale reading is never used as if it were current, whether it came from
the pump or from Share.
