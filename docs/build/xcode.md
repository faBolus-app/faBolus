# 2 · Install Xcode

**Xcode** is Apple's free tool for building apps. It's a big download, so start it now and read
on while it installs — grab a coffee.

## Step 1 — Get Xcode from the App Store

<ol class="cx2-steps">
<li>On your Mac, open the <strong>App Store</strong>.</li>
<li>Search for <strong>Xcode</strong>.</li>
<li>Click <strong>Get</strong>, then <strong>Install</strong>. Now wait — it's several gigabytes and can take a while. That's normal.</li>
</ol>

!!! note "If the App Store won't install it"
    Xcode needs a fairly recent macOS. If it refuses, update your Mac first
    (**Apple menu → System Settings → General → Software Update**), then try again. You need
    **Xcode 16 or newer**.

## Step 2 — Open Xcode once

The first launch sets up a few extra pieces.

<ol class="cx2-steps">
<li>Open <strong>Xcode</strong> from your Applications.</li>
<li>If it offers to install <strong>additional components</strong>, click <strong>Install</strong> and type your Mac password.</li>
<li>If it asks which <strong>platforms</strong> you want, make sure <strong>iOS</strong> is included (add <strong>watchOS</strong> too if you'll build the Apple Watch app). Let them download.</li>
</ol>

## Step 3 — Tell Xcode who you are

This links Xcode to the Apple account from [Step 1](apple-developer.md).

<ol class="cx2-steps">
<li>In the menu bar: <strong>Xcode → Settings…</strong></li>
<li>Click the <strong>Accounts</strong> tab.</li>
<li>Click the <strong>+</strong> at the bottom-left → <strong>Apple ID</strong> → sign in.</li>
</ol>

<div class="cx2-check" markdown>
**Success looks like:** your name appears in the Accounts list with a **Team** under it —
"(Personal Team)" for a free account, or your name for a paid one. You'll pick this Team later.
</div>

## Step 4 — Install two small helpers

The project uses a couple of free tools. The easiest way to get them is **Homebrew**, a popular
installer for the Mac. You'll paste one or two lines into the **Terminal** app (in Applications →
Utilities) — you don't need to understand them, just paste and press Return.

=== "I don't have Homebrew yet"

    Paste this and follow the prompts:

    ```sh
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ```

    When it finishes, paste this to install the project helper:

    ```sh
    brew install xcodegen
    ```

=== "I already have Homebrew"

    ```sh
    brew install xcodegen
    ```

!!! info "What did that install?"
    **XcodeGen** builds the Xcode project file from a simple text file in the app, so you always
    get a clean, correct setup. You'll run it once in the next step.

<div class="cx2-check" markdown>
**You're ready** when Xcode is installed, your Apple ID is under **Settings → Accounts**, and
`xcodegen --version` prints a number in Terminal. Next: [Put the app on your iPhone →](build-app.md)
</div>
