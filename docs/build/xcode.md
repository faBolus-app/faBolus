# 2 · Install Xcode

**Xcode** is Apple's free app for building apps. It's a big download (several gigabytes), so
start this early and let it run while you read ahead.

## Step A — Install Xcode from the Mac App Store

<ol class="cx2-steps">
<li>On your Mac, open the <strong>App Store</strong>.</li>
<li>Search for <strong>Xcode</strong> and click <strong>Get</strong> / <strong>Install</strong>.</li>
<li>Wait for it to finish downloading and installing. This can take a while — it's normal.</li>
</ol>

!!! tip "Make sure your macOS is recent enough"
    Each Xcode version needs a recent macOS. If the App Store won't let you install the latest
    Xcode, update macOS first (**Apple menu → System Settings → General → Software Update**).
    ControlX2iOS needs **Xcode 16 or newer**.

## Step B — Open Xcode once and finish setup

The first time you open Xcode it installs some extra components.

<ol class="cx2-steps">
<li>Open <strong>Xcode</strong> from Applications.</li>
<li>If it offers to install <strong>additional required components</strong>, click <strong>Install</strong> and enter your Mac password.</li>
<li>If asked which <strong>platforms</strong> to support, make sure <strong>iOS</strong> is included (add <strong>watchOS</strong> too if you'll build the Apple Watch app). Let those finish downloading.</li>
</ol>

## Step C — Sign in to Xcode with your Apple ID

This links Xcode to the account from [step 1](apple-developer.md) so it can sign your app.

<ol class="cx2-steps">
<li>In Xcode's menu bar: <strong>Xcode → Settings…</strong> (older versions: <em>Preferences…</em>).</li>
<li>Click the <strong>Accounts</strong> tab.</li>
<li>Click the <strong>+</strong> at the bottom-left, choose <strong>Apple ID</strong>, and sign in.</li>
<li>You should now see your name with a <strong>team</strong> underneath — either "(Personal Team)" for a free account, or your name/organization for a paid one. You'll pick this team when building.</li>
</ol>

## Step D — Install Homebrew and XcodeGen

ControlX2iOS uses a small helper called **XcodeGen** to create the Xcode project from a simple
text file (`project.yml`). The easiest way to install it is with **Homebrew**, a popular
package manager for the Mac.

=== "If you don't have Homebrew"

    Open the **Terminal** app (in Applications → Utilities) and paste this line, then press
    Return and follow the prompts:

    ```sh
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ```

    When it finishes, install XcodeGen:

    ```sh
    brew install xcodegen
    ```

=== "If you already have Homebrew"

    ```sh
    brew install xcodegen
    ```

!!! info "What's the Terminal?"
    The Terminal is a text-based way to run commands on your Mac. You'll use it for a couple of
    copy-paste commands in this guide — you don't need to understand them, just paste and press
    Return.

## What you should have now

- [x] Xcode installed and opened once (components finished installing).
- [x] Your Apple ID added under **Xcode → Settings → Accounts**, showing a team.
- [x] `xcodegen` installed (check by running `xcodegen --version` in Terminal).

Next: [Build the iPhone app :material-arrow-right:](build-app.md)
