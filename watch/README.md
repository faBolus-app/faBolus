# watch — watchOS remote

A modern Apple Watch remote at parity with the phone. It never touches the pump — it relays
bolus requests to the iPhone host over WatchConnectivity, and the phone confirms and delivers.
Screens: glance, chart, details, alerts; plus a watch-face **complication**.

- `faBolusWatch/` — the watch app.
- `faBolusWatchWidgets/` — the glucose watch-face complication.

**Build & usage:** see the docs — [add the Apple Watch app](../docs/build/apple-watch-build.md)
and [Apple Watch remote](../docs/remotes/apple-watch.md).

> A standalone build (running `PumpX2Kit` on-watch, no phone) is designed but not built, and not yet
> documented. (Design notes live with the watch-install / independent-pairing work, currently paused.)
