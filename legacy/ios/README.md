# ios — iOS host app

The iPhone app. It owns the pump's Bluetooth connection via
[`TandemKit`](https://github.com/faBolus-app/TandemKit) and provides the tabbed UI (Dashboard,
Bolus, Alerts, Settings), the widget extension, and the bridge to the Garmin remote.

- `faBolus/` — the main app (Data sources, Views, Models, the Garmin remote bridge).
- `faBolusWidgets/` — the WidgetKit extension (Lock/Home Screen widgets + Quick Bolus).

**Build & usage:** see the docs — [build guide](../docs/build/build-app.md) and
[using the app](../docs/operate/status.md). Requires **Xcode 16+** and an **Apple ID** (free
works; paid recommended). In development for experimental use.
