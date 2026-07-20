# 3 · Put the app on your iPhone

This is the main event: download the code, press one button, and the app appears on your phone.
Go slowly and do the steps in order. None of it needs coding.

## Step 1 — Download the code {#download}

The app is built on a companion library called **PumpX2Kit**, and the two folders need to sit
**next to each other**. The easiest way is to make one folder and put both inside it.

Open the **Terminal** app (Applications → Utilities) and paste each block, pressing Return after
each:

```sh
# Make a folder and go into it
mkdir -p ~/ControlX2 && cd ~/ControlX2

# Download both projects (the --recurse-submodules part grabs some extra files they need)
git clone --recurse-submodules https://github.com/zgranowitz/PumpX2Kit.git
git clone https://github.com/zgranowitz/ControlX2iOS.git
```

<div class="cx2-check" markdown>
**Success looks like:** you now have two folders, `~/ControlX2/PumpX2Kit` and
`~/ControlX2/ControlX2iOS`.
</div>

!!! note "If you later see errors about missing `mbedtls` files"
    A small extra piece didn't download. Fix it with:

    ```sh
    cd ~/ControlX2/PumpX2Kit && git submodule update --init --recursive
    ```

## Step 2 — Add the Garmin helper file {#connectiq}

The app is wired to talk to Garmin watches, so it needs one file from Garmin — **even if you
never use a Garmin.** You download it once and drop it in place.

<ol class="cx2-steps">
<li>Go to the <a href="https://developer.garmin.com/connect-iq/sdk/">Garmin Connect IQ SDK page</a> and download the <strong>Connect IQ Companion (Mobile) SDK for iOS</strong>. (Free Garmin account; accept the license.)</li>
<li>Unzip it. You want the folder named like <code>connectiq-companion-app-sdk-ios-1.8.0</code>.</li>
<li>Put it in a <code>vendor</code> folder next to your projects — paste this in Terminal (adjust the version if yours differs):

<div></div>

```sh
mkdir -p ~/ControlX2/vendor
mv ~/Downloads/connectiq-companion-app-sdk-ios-1.8.0 ~/ControlX2/vendor/
```
</li>
</ol>

!!! info "Why is this needed for an iPhone-only build?"
    The app *includes* the Garmin bridge, so Xcode needs this file to build even if you don't own
    a Garmin. If you keep the file somewhere else, open `ControlX2iOS/project.yml`, find
    `ConnectIQ:` → `path:`, and point it at your folder (then re-run the next step).

## Step 3 — Create the project

This turns the code into something Xcode can open.

```sh
cd ~/ControlX2/ControlX2iOS
xcodegen generate
```

<div class="cx2-check" markdown>
**Success looks like:** a new file **`ControlX2.xcodeproj`** appears in the folder.
</div>

## Step 4 — Open it in Xcode

```sh
open ControlX2.xcodeproj
```

Give Xcode a minute — a bar at the top says it's "resolving packages" (fetching PumpX2Kit). Wait
for it to finish.

## Step 5 — Choose your Team {#your-team}

This is the step people trip on, so take it slowly. It tells Xcode to sign the app with *your*
Apple account.

<ol class="cx2-steps">
<li>In the left panel, click the blue <strong>ControlX2</strong> icon at the very top.</li>
<li>In the middle, under <strong>TARGETS</strong>, click <strong>ControlX2</strong>.</li>
<li>Click the <strong>Signing &amp; Capabilities</strong> tab.</li>
<li>Tick <strong>Automatically manage signing</strong>.</li>
<li>Set <strong>Team</strong> to your name (the account from <a href="apple-developer.md">Step 1</a>).</li>
</ol>

Do the same **Team** choice for the other targets in the TARGETS list too:
**ControlX2Widgets**, **ControlX2Watch**, and **ControlX2WatchWidgets**.

<figure class="cx2-shot wide" markdown="span">
  ![Xcode Signing & Capabilities tab](../assets/screenshots/xcode-signing.svg)
  <figcaption>Signing &amp; Capabilities → tick "Automatically manage signing", pick your Team</figcaption>
</figure>

!!! warning "Free account? You'll probably see a red \"identifier is not available\" error"
    Every app needs a name that's unique across everyone. The project ships with
    `com.zgranowitz.controlx2`, which is taken. Change the front part to your own — for example
    `com.yourname` — everywhere it appears in `ControlX2iOS/project.yml` (the `bundleIdPrefix`,
    each `PRODUCT_BUNDLE_IDENTIFIER`, and the `group.com.zgranowitz.controlx2` line). Keep the
    endings the same (`.widgets`, `.watch`, `group.…`). Then run `xcodegen generate` again and
    reopen the project. This is normal and only takes a minute.

!!! info "Free account and the widgets"
    A free account sometimes can't set up widgets. If a widget target won't sign, you can still
    run the main app — build just **ControlX2** for now and add widgets later on a paid account.

## Step 6 — Plug in your iPhone and press Run

<figure class="cx2-shot wide" markdown="span">
  ![Choosing your iPhone and pressing Run in Xcode](../assets/screenshots/xcode-run.svg)
  <figcaption>Pick your iPhone at the top, then press ▶</figcaption>
</figure>

<ol class="cx2-steps">
<li>Connect your iPhone to the Mac with a cable. If the phone asks, tap <strong>Trust This Computer</strong> and enter your passcode.</li>
<li>If your iPhone asks you to turn on <strong>Developer Mode</strong>: <strong>Settings → Privacy &amp; Security → Developer Mode</strong> → on, then restart the phone.</li>
<li>At the top of Xcode, click the device menu and pick <strong>your iPhone</strong> (under "iOS Device").</li>
<li>Press the <strong>▶</strong> button (top-left), or press <kbd>⌘</kbd> + <kbd>R</kbd>.</li>
</ol>

The first build takes a few minutes. Let it work.

## Step 7 — Let your phone trust the app

The first time, iOS won't open an app from a developer it doesn't know yet — that's you.

<figure class="cx2-shot phone" markdown="span">
  ![Trusting the developer profile in iPhone Settings](../assets/screenshots/developer-trust.svg)
  <figcaption>Settings → General → VPN &amp; Device Management → tap your profile → Trust</figcaption>
</figure>

<ol class="cx2-steps">
<li>On the iPhone: <strong>Settings → General → VPN &amp; Device Management</strong>.</li>
<li>Under <strong>Developer App</strong>, tap your account.</li>
<li>Tap <strong>Trust</strong>, then confirm.</li>
</ol>

## Step 8 — Open it and allow Bluetooth

Tap the **ControlX2** icon on your Home Screen. The first time you tap **Connect**, iOS asks to
use Bluetooth — tap **Allow** (the app can't find your pump without it).

<div class="cx2-check" markdown>
**🎉 You did it.** The app is on your iPhone. Until you pair a pump it shows a waiting screen.
Next up:

- [Pair it with your pump →](../setup/pairing.md)
- Optional: [add the Apple Watch app](apple-watch-build.md) or [a Garmin](garmin-build.md)
- Learn [what everything does](../operate/status.md)
</div>

!!! note "Remember the expiry"
    Free account: the app stops opening after 7 days — just [re-install](updating.md) (a minute).
    Paid: once a year.
