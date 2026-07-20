# Keeping the app running

Because you install faBolus yourself (not from the App Store), it has an expiry date. This
page explains why, and the quick routine to keep it working. Good news: it's almost all clicking.

## Why it expires

The certificate that signs your app has a limited life:

| Account | The app keeps working for |
| --- | --- |
| Free Apple ID | **7 days** |
| Apple Developer Program ($99/yr) | **1 year** |

When it expires, the icon stays on your Home Screen but the app won't open (or shows a signing
error). Nothing is broken — it just needs re-installing.

## The quick reinstall (about a minute)

<ol class="cx2-steps">
<li>Plug your iPhone into the Mac.</li>
<li>In Finder, open <strong>Documents → faBolus → faBolus</strong> and double-click <strong>faBolus.xcodeproj</strong>.</li>
<li>Pick your iPhone in the device bar at the top and click <strong>▶ Run</strong> (or press <kbd>⌘</kbd> + <kbd>R</kbd>).</li>
<li>If the phone asks you to <strong>Trust</strong> the developer again, do so (<a href="build-app.md#step-8-let-your-phone-trust-the-app">Step 8</a>).</li>
</ol>

That's it — the fresh install resets the clock. Your saved pump pairing stays put (it's stored
securely on the phone), so you won't need the 6-digit code again.

!!! tip "Put a reminder on your calendar"
    On a free account, a weekly reminder saves you from finding an expired app right when you need
    it. On the paid program, once a year is plenty.

## Getting the newest version of the app

When the project gets updates, refresh your copy with **GitHub Desktop** — no commands:

<ol class="cx2-steps">
<li>Open <strong>GitHub Desktop</strong>.</li>
<li>Pick <strong>PumpX2Kit</strong> from the repository list (top-left), then click <strong>Fetch origin</strong> → <strong>Pull origin</strong>.</li>
<li>Do the same for <strong>faBolus</strong>.</li>
<li>Re-do <a href="build-app.md#step-3-create-the-project-the-one-terminal-step">Step 3b</a> (<code>xcodegen generate</code>) in case files were added, then open the project and <strong>Run</strong>.</li>
</ol>

??? note "Advanced: update from the Terminal (optional)"
    ```sh
    cd ~/Documents/faBolus/PumpX2Kit && git pull --recurse-submodules
    cd ~/Documents/faBolus/faBolus && git pull
    xcodegen generate
    open faBolus.xcodeproj
    ```

If a build ever fails right after updating, see [Troubleshooting](../troubleshoot.md) — the usual
fixes are re-fetching the helper files and re-running `xcodegen generate`.

## Updating the watch and Garmin apps

- **Apple Watch:** run it again from Xcode — see [Add the Apple Watch](apple-watch-build.md).
- **Garmin:** rebuild and re-install it — see [Add a Garmin](garmin-build.md). The Garmin app
  doesn't expire like the iOS app does; you only reinstall it to get changes.
