# Keeping the app running

Because you install ControlX2iOS yourself (not from the App Store), it has an expiry date. This
page explains why, and the quick routine to keep it working.

## Why it expires

The certificate that signs your app has a limited life:

| Account | The app keeps working for |
| --- | --- |
| Free Apple ID | **7 days** |
| Apple Developer Program ($99/yr) | **1 year** |

When it expires the icon stays on your Home Screen but the app refuses to open (or shows a
signing error). Nothing is wrong — it just needs to be re-signed.

## The quick reinstall

<ol class="cx2-steps">
<li>Plug your iPhone into the Mac.</li>
<li>Open <strong>ControlX2.xcodeproj</strong> in Xcode (in <code>~/ControlX2/ControlX2iOS</code>).</li>
<li>Select your iPhone in the device menu and press <strong>▶ Run</strong> (<kbd>⌘</kbd> + <kbd>R</kbd>).</li>
</ol>

That's it — the fresh install resets the clock. Your saved pump pairing stays put (it's stored
securely in the iOS Keychain), so you won't need the 6-digit code again.

!!! tip "Put a reminder on the calendar"
    On a free account, a weekly reminder saves you from discovering an expired app right when you
    want it. On the paid program, once a year is plenty.

## Getting the latest code changes

To pick up updates to the project itself:

```sh
cd ~/ControlX2/PumpX2Kit && git pull --recurse-submodules
cd ~/ControlX2/ControlX2iOS && git pull

# Regenerate the Xcode project in case the structure changed, then reopen
xcodegen generate
open ControlX2.xcodeproj
```

Then **Run** as usual. If a build ever fails right after pulling, see
[Troubleshooting](../troubleshoot.md) — the usual fixes are re-fetching submodules and
re-running `xcodegen generate`.

## Updating the watch and Garmin apps

- **Apple Watch:** re-run the **ControlX2Watch** scheme from Xcode ([step 4](apple-watch-build.md)).
- **Garmin:** rebuild `ControlX2.prg` and copy it to the watch again
  ([step 5](garmin-build.md)). The Garmin app doesn't expire the way the iOS app does, but you'll
  reinstall it to get changes.
