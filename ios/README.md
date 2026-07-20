# ios — iOS host app

The iPhone app. It owns the pump's Bluetooth connection via
[`PumpX2Kit`](https://github.com/zgranowitz/PumpX2Kit) and provides the tabbed modern UI
(Dashboard, Bolus, Alerts, Settings), the widget extension, Siri/App Intents, and the bridges to
the Apple Watch and Garmin remotes.

- `ControlX2/` — the main app (Data sources, Views, Models, Intents, remote bridges).
- `ControlX2Widgets/` — the WidgetKit extension (Lock/Home Screen widgets + Quick Bolus).

**Build & usage:** see the docs — [build guide](../docs/build/build-app.md) and
[using the app](../docs/operate/status.md). Requires **Xcode 16+** and an **Apple ID** (free
works; paid recommended). In development for experimental use.
