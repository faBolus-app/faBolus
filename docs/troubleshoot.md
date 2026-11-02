# Troubleshooting

Common problems, by where you hit them. If yours isn't here, see the [FAQ](faq.md) or
[send feedback](feedback.md).

## Building the app

??? question "`xcodegen: command not found`"
    XcodeGen isn't installed, or Terminal doesn't know about Homebrew yet. Do
    [Install Homebrew and XcodeGen](build/xcode.md#step-3-install-homebrew-and-xcodegen) again, including
    the **Next steps** commands Homebrew prints, then open a new Terminal window.

??? question "\"Failed to register bundle identifier\" or \"App Group is not available\""
    The bundle ID is taken: every App ID and App Group is unique across Apple. Set your own
    `APP_BUNDLE_ID` in `LocalConfig.xcconfig` (see [Your details](build/build-app.md#your-details)), make
    the project again with `./scripts/generate-project.sh`, and reopen it.

??? question "\"Signing requires a development team\""
    No team is set. Put your Team ID in `LocalConfig.xcconfig` and make the project again, or pick your
    team under **Signing & Capabilities** for both **faBolus** and **faBolusWidgets**. If the file still
    has the example's `ABCDE12345`, replace it.

??? question "Package resolution fails, or a TandemKit or mbedTLS file is missing"
    Xcode's download of a library was interrupted. In Xcode choose **File → Packages → Reset Package
    Caches**, then **File → Packages → Resolve Package Versions**, and wait for it to finish. Check that
    the Mac is online: the libraries come from GitHub.

??? question "Garmin's SDK isn't found, or the build says Garmin: off"
    The folder must be exactly `Developer/vendor/connectiq-companion-app-sdk-ios-1.8.0`, two folders up
    from the app (see [Garmin's SDK](build/build-app.md#garmin-sdk)), and contain
    `ConnectIQ.xcframework`. Move it there and make the project again.

??? question "A build fails right after an update"
    Make the project again (`./scripts/generate-project.sh`), since files may have been added. If it
    still fails, choose **Product → Clean Build Folder** in Xcode and build again.

??? question "The app won't open any more"
    Its signing ran out: 7 days on a free account, a year on a paid one. Install it again; see
    [Keeping it running](build/updating.md).

## Pairing and connecting

??? question "The pump doesn't appear"
    - Put the pump in pairing mode: **Options → Device Settings → Bluetooth Settings**, **Mobile
      Connection** on, then **Pair Device**.
    - Make sure faBolus may use Bluetooth: iPhone **Settings → faBolus → Bluetooth**.
    - Disconnect or unpair t:connect: the pump connects to one app at a time.
    - Wait for **Search again**, then try once more with the phone next to the pump.

??? question "Pairing fails"
    Pair Device shows a new code each time. Enter the code the pump shows now, exactly: the 16-character
    code is case-sensitive. Then try again.

??? question "\"Connection unstable\" or the pump keeps disconnecting"
    Keep the phone closer to the pump. **Settings → Pump** says why the link last dropped. If it keeps
    happening, export diagnostics (**Settings → About & help**) and [send them](feedback.md).

## Using it

??? question "Confirm is greyed out or a bolus is refused"
    The line under the dose says why: for example the pump isn't connected, a bolus is running, or an
    earlier bolus's outcome is unknown. For an unknown outcome, check the pump's history and use
    **I checked the pump** on the dashboard. The pump also refuses a dose over its own maximum or without
    a cartridge.

??? question "The suggested dose says it's waiting for the pump's settings"
    faBolus hasn't read the pump's bolus settings and active insulin yet, or they're too old. Keep the pump
    connected for a moment. You can still enter units.

??? question "Glucose is grey or shows \"—\""
    The reading is older than your freshness window, so it isn't shown as current. Check the CGM on the
    pump, or set up a [backup CGM](setup/cgm.md).

??? question "A cleared alert comes back"
    Some alerts come back while their cause lasts, such as a CGM high while glucose is still high. Clear
    them on the pump.

??? question "Notifications don't arrive, or don't come through a Focus"
    Check iPhone **Settings → Notifications → faBolus**; a banner in the app also says when they're off.
    Breaking through a Focus needs the Time Sensitive capability, which needs a paid account (see the
    [build guide](build/build-app.md#step-4-make-the-xcode-project)).

## Backup CGM

??? question "Dexcom Share doesn't connect"
    Check the username, password and region, and that Share is on in the Dexcom app. The phone needs
    internet.

??? question "The direct G6 or G7 doesn't get readings"
    Keep the Dexcom app installed, paired and running. For G6, check the transmitter ID, or clear it to
    use the pump's. The **Status** line says what's wrong. If it keeps failing, export the Dexcom Bluetooth
    log (**Settings → About & help**) and [send it](feedback.md).

## Garmin watch

??? question "Settings → Watch says Garmin isn't included"
    The app was built without Garmin's SDK. Add it ([Garmin's SDK](build/build-app.md#garmin-sdk)), make the
    project again and run it on the phone.

??? question "The watch says \"Phone not connected\" or \"No reply from faBolus\""
    The phone must be near the watch, with Bluetooth on and Garmin Connect running. Open faBolus on the
    phone. In **Settings → Watch**, check the chosen watch, or choose it again in Garmin Connect.

??? question "**Link** says \"faBolus not installed on the watch\""
    The watch app isn't installed, or it was built with a different app ID than the phone expects. Install
    it as in [Garmin watch (build)](build/garmin-build.md). If you used a private beta, make sure the phone
    app was built after `beta-build.sh` set your ID.

??? question "The watch offers no bolus"
    Turn on **Allow bolusing from the watch** in **Settings → Watch** on the phone, and check that
    **Read-only** is off there. The watch's bolus screen says what's stopping it.

??? question "A complication shows `--` or nothing"
    `--` means the value is too old to show. Open faBolus on the phone to refresh it. Garmin's stock faces
    may not show third-party complications; use a face that does, such as Face It.
