# Keeping it running and updating

## Why the app expires

An app you install yourself is signed with a certificate that runs out:

| Account | The app keeps opening for |
| --- | --- |
| Free Apple account | **7 days** |
| Apple Developer Program | **1 year** |

When it runs out, the icon stays but the app won't open. Nothing is lost: install it again.

## Install again (about a minute)

<ol class="cx2-steps">
<li>Connect the iPhone to the Mac.</li>
<li>Open <strong>Developer → faBolus → faBolus → faBolus.xcodeproj</strong>.</li>
<li>Choose your iPhone at the top of Xcode and press <strong>▶</strong> (Run).</li>
</ol>

Your pairing, settings and history stay on the phone, so you don't pair again.

!!! tip "Set a reminder"
    While the app won't open, nothing of faBolus runs: no notifications, no backup urgent low, nothing on
    the watch or in the widgets. Your pump's own alarms carry on. On a free account, a weekly calendar
    reminder saves you from finding the app expired when you need it.

## Get the newest version

1. Open **GitHub Desktop**, choose **faBolus** in the repository list at the top left, and click
   **Fetch origin**, then **Pull origin** if it offers it.
2. Quit Xcode. In Terminal, make the project again, since files may have been added. Put
   `FABOLUS_TIME_SENSITIVE=1` in front if you built with it:

    ```sh
    cd ~/Developer/faBolus/faBolus
    ./scripts/generate-project.sh
    ```

3. Open the project and press **Run**.

If the build fails right after an update, see [Troubleshooting](../troubleshoot.md#building-the-app).

### The watch app

The watch app doesn't expire. Update it when the phone app's update needs it: pull **faBolusGarmin** in
GitHub Desktop the same way, then build and install it again as in
[Garmin watch](garmin-build.md#step-5-build-the-watch-app). When the phone and watch apps are too far
apart to talk, the watch says which one to update.

## Coming from the earlier faBolus

This version is a new app.

**Your folders.** The earlier guide kept the code in `Documents/faBolus/faBolus`, with a TandemKit clone
beside it and Garmin's SDK in `Documents/vendor`. You can keep using that folder: pull the update, and use
`cd ~/Documents/faBolus/faBolus` wherever this guide says `~/Developer/faBolus/faBolus`. The SDK in
`Documents/vendor` is still found, two folders up. The TandemKit clone isn't needed any more. If a
repository you cloned in Terminal doesn't appear in GitHub Desktop, add it with **File → Add Local
Repository…**. Or start fresh with [the build guide](build-app.md).

**Your data.** If you built the earlier faBolus with the same bundle ID, the new one installs over it, and
on its first launch it removes everything the earlier app stored on the phone:

- its settings;
- its pump pairing, so you [pair again](../setup/pairing.md) with a new code from the pump;
- its Dexcom Share login, so you sign in again under [Backup CGM](../setup/cgm.md);
- its history and the files it shared with the widgets.

The new app doesn't read the earlier app's bolus records. Before you switch, let any bolus finish and
check the pump's own history.

The earlier and the new watch apps don't talk to each other's phone apps. Update the watch app at the
same time: an earlier watch app on the new phone app shows **Update watch app**, and the new watch app
with the earlier phone app shows **Update faBolus on phone**.

If you built the earlier app with a different bundle ID, the new one installs beside it. Delete the
earlier app from the iPhone so only one of them connects to the pump.
