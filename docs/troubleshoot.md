# Troubleshooting

Common snags, grouped by where you hit them. If something here doesn't cover it, check the
[FAQ](faq.md).

## Building the app

??? question "Build fails right after downloading — missing `mbedtls` files"
    PumpX2Kit's crypto submodule wasn't fetched. Run:

    ```sh
    cd ~/faBolus/PumpX2Kit && git submodule update --init --recursive
    ```

??? question "Xcode can't find the ConnectIQ package"
    The Connect IQ **Mobile** SDK isn't where `project.yml` expects it. Re-check
    [Step 2 of the build](build/build-app.md#connectiq), place the
    `connectiq-companion-app-sdk-ios-1.8.0` folder correctly (or edit the `ConnectIQ` `path:` in
    `project.yml`), then re-run `xcodegen generate` and reopen the project.

??? question "\"Failed to register bundle identifier\", \"An Application Group … is not available\", or other signing errors"
    App IDs and App Groups must be unique across all of Apple, so the default `com.fabolus.app`
    (owned by the faBolus team) can't be reused by your account. Set your own: copy
    `LocalConfig.xcconfig.example` to **`LocalConfig.xcconfig`**, set **`APP_BUNDLE_ID`** to a
    value unique to you (and **`DEVELOPMENT_TEAM`** to your Team ID), then run `xcodegen generate`
    again. The watch app, widgets, and App Group all update from that one value. See the
    [signing note](build/build-app.md#your-team).

??? question "The widget target won't sign on a free account"
    Free \"Personal Team\" accounts sometimes can't register App Groups or app extensions. Build
    just the main **faBolus** app for now; add the widgets once you're on the paid Apple
    Developer Program.

??? question "I changed `project.yml` and nothing happened"
    Re-run `xcodegen generate` and reopen `faBolus.xcodeproj` — the project file is generated
    from `project.yml`, so edits only take effect after regenerating.

??? question "The app expired / won't open"
    That's the signing certificate's normal life (7 days on free, 1 year on paid). Just
    reinstall — see [Keeping the app running](build/updating.md).

## Connecting & pairing

??? question "Can't find or connect to the pump"
    - Make sure the official Tandem **t:connect** app is unpaired/closed — only one control
      connection is allowed at a time.
    - Confirm Bluetooth permission is granted to faBolus (**Settings → faBolus → Bluetooth**).
    - Put the pump in pairing mode; the app scans for the Tandem service (`0000fdfb…`).

??? question "Pairing fails"
    - Double-check the code type (16-char vs 6-digit) matches your pump's firmware.
    - For a 6-digit (JPAKE) code, a **wrong** code still completes the handshake but fails
      **key confirmation** — re-enter the correct code.

## Using it

??? question "A bolus is rejected"
    - The command must be correctly signed with a recent pump time. Reconnect to refresh timing.
    - Check the max-units clamp — the pump also rejects anything over its own configured max.

??? question "A watch/Garmin request doesn't deliver"
    - The iPhone does the actual delivery, so it must be **reachable and connected to the pump**.
    - You confirm the bolus on the watch itself (the deliberate confirmation); the
      phone then delivers.
    - If the phone is out of range, the request fails cleanly on the watch — reconnect and retry.

??? question "A cleared alert comes back"
    Some alerts are **condition-based** (e.g. a high-glucose alert re-raises while BG is still
    high). Also note the dismiss path isn't fully verified yet — see
    [Alerts & alarms](operate/alerts.md).

## Watch & Garmin

??? question "The Apple Watch app won't install"
    Watch installs are finicky: keep the watch on its charger and unlocked, install the phone app
    first, then retry — or install from the **Watch** app on the iPhone
    (**My Watch → Available Apps**).

??? question "The Garmin complication shows `--` or nothing"
    - It needs the iPhone app open and connected for fresh data.
    - Stock Garmin faces can't show third-party data — use a **Face It** or CIQ face that
      supports complications and add the *faBolus BG* field.
