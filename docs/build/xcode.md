# 2 · Install Xcode

## What is Xcode?

**Xcode** is a free program made by Apple for Apple computers. You'll use it to turn the app's
"raw" code into a real app and put it on your iPhone. Think of it as the oven that bakes the app
from the recipe.

It's a **big** download (several gigabytes), so start it now and read on while it installs.

## Step 1 — Get Xcode from the App Store

<ol class="cx2-steps">
<li>On your Mac, open the <strong>App Store</strong> (the blue "A" icon).</li>
<li>In the search box (top-left), type <strong>Xcode</strong> and press Return.</li>
<li>Click <strong>Get</strong>, then <strong>Install</strong>. Now wait — it's large and can take 20–60 minutes. That's completely normal.</li>
</ol>

!!! note "If the App Store won't let you install it"
    Xcode needs a fairly up-to-date Mac. If it says you can't install it, update your Mac first —
    click the **Apple menu** (top-left) → **System Settings** → **General** → **Software Update**
    — then try the App Store again. You need **Xcode 16 or newer**.

## Step 2 — Open Xcode once and let it finish

The very first time you open Xcode, it downloads a few more pieces. Let it.

<ol class="cx2-steps">
<li>Open <strong>Xcode</strong> from your Applications folder (or Launchpad).</li>
<li>If a window offers to install <strong>additional required components</strong>, click <strong>Install</strong> and type your Mac password.</li>
<li>If it asks which <strong>platforms</strong> you want to support, make sure <strong>iOS</strong> is ticked. Tick <strong>watchOS</strong> too if you plan to use an Apple Watch. Let them download.</li>
</ol>

!!! tip "You can leave Xcode open"
    Once it's done, you can leave Xcode open — you'll use it in the next step.

## Step 3 — Tell Xcode who you are

This connects Xcode to the Apple account you set up in [Step 1](apple-developer.md), so it's
allowed to put apps on *your* phone.

<ol class="cx2-steps">
<li>In the menu bar at the very top of the screen: click <strong>Xcode</strong> → <strong>Settings…</strong></li>
<li>Click the <strong>Accounts</strong> tab.</li>
<li>Click the <strong>+</strong> button (bottom-left) → choose <strong>Apple ID</strong> → sign in with your Apple ID.</li>
</ol>

<div class="cx2-check" markdown>
**Success looks like:** your name now appears in the Accounts list, with a **Team** listed under
it — either **(Personal Team)** for a free account, or your name for a paid one. Xcode will use
this "Team" to sign the app later. You don't need to do anything else with it here.
</div>

<div class="cx2-check" markdown>
**Next:** [Step 3 · Put it on your iPhone →](build-app.md). That page gets you a couple of free
helper tools and then installs the app.
</div>
