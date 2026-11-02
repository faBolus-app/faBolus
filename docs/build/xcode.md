# 2 · Xcode and tools

You'll install three things: **Xcode**, a small tool called **XcodeGen**, and **GitHub Desktop**.

## Step 1: Install Xcode

**Xcode** is Apple's free app for building apps. It's a large download, so start it first.

<ol class="cx2-steps">
<li>On your Mac, open the <strong>App Store</strong>, search for <strong>Xcode</strong>, and click <strong>Get</strong>, then <strong>Install</strong>. It can take 20 to 60 minutes.</li>
<li>Open <strong>Xcode</strong> from your Applications folder. If it offers to install <strong>additional components</strong>, click <strong>Install</strong> and enter your Mac password.</li>
<li>When it asks which <strong>platforms</strong> to download, make sure <strong>iOS</strong> is included, and let it finish.</li>
</ol>

faBolus is built and tested with **Xcode 27.2**; an older Xcode doesn't work. A newer one usually does,
but the project treats every compiler warning as an error, so a newer Xcode's new warnings can stop the
build. If that happens, install 27.2 from [Apple's downloads page](https://developer.apple.com/download/all/).
To see your version, choose **Xcode → About Xcode** in the menu bar.

!!! note "If the App Store won't install it"
    Xcode needs a recent macOS. Update your Mac in **System Settings → General → Software Update** and
    try again.

## Step 2: Sign in to Xcode

<ol class="cx2-steps">
<li>In the menu bar, choose <strong>Xcode → Settings…</strong> and click <strong>Accounts</strong>.</li>
<li>Click <strong>+</strong> (bottom left), choose <strong>Apple Account</strong>, and sign in.</li>
</ol>

<div class="cx2-check" markdown>
**Success looks like:** your name in the list, with a **team** under it: "(Personal Team)" for a free
account, or your name for a paid one. Xcode uses this team to sign the app.
</div>

## Step 3: Install Homebrew and XcodeGen

The app's Xcode project isn't stored in the repository. A tool called **XcodeGen** makes it from a short
description file. You install XcodeGen with **Homebrew**, the usual way to install small Mac tools.

Open **Terminal** (in **Applications → Utilities**). You type or paste a command, press Return, and wait
until it finishes before the next.

**If you don't have Homebrew yet**, paste this and follow what it prints. It needs an administrator
account on the Mac, and asks for your Mac password; the characters don't show as you type, which is
normal.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

At the end Homebrew prints **Next steps** with one or two commands to run. Run them, then close the
Terminal window and open a new one.

Then install XcodeGen:

```sh
brew install xcodegen
```

<div class="cx2-check" markdown>
**Success looks like:** `xcodegen --version` prints a version number.
</div>

## Step 4: Install GitHub Desktop

The code lives on **GitHub**, a website for sharing code. **GitHub Desktop** downloads it, and later
fetches updates, with buttons instead of commands.

Download it from [desktop.github.com](https://desktop.github.com/), move it to Applications and open it.
Signing in to GitHub is optional; you can skip it.

<div class="cx2-check" markdown>
**Next:** [Step 3 · Put it on your iPhone →](build-app.md)
</div>
