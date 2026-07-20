# 1 · Apple ID & Developer account

To install an app you built onto your own iPhone, Apple needs to know who you are. That's what
an **Apple ID** and a **developer account** are for. This is the same first step as building
Loop — if you've done that, you can reuse the same account.

<figure class="cx2-shot wide" markdown="span">
  ![Apple Developer enrollment page](../assets/screenshots/appledev-enroll.svg)
  <figcaption>The Apple Developer site — where you sign in and (optionally) enroll</figcaption>
</figure>

## Free or paid?

You have two choices. Both work. The difference is how often you have to rebuild.

<div class="grid cards" markdown>

-   :material-cash-remove:{ .lg .middle } **Free Apple ID** <span class="cx2-tag now">good to start</span>

    ---

    Any Apple ID can build and install apps for free. The catch: the app **stops working after
    7 days** and you reinstall it from Xcode to reset the clock. Fine for trying things out.

-   :material-cash:{ .lg .middle } **Apple Developer Program** <span class="cx2-tag now">recommended</span>

    ---

    $99/year. Apps last **a full year** before needing a rebuild, and widgets / watch features
    are more reliable. Worth it if you'll use this regularly.

</div>

## Step A — Make sure you have an Apple ID

You almost certainly already have one (it's the account you use for the App Store, iCloud, etc.).
If not:

<ol class="cx2-steps">
<li>On your iPhone, open <strong>Settings</strong> and tap <strong>Sign in to your iPhone</strong> at the top.</li>
<li>Tap <strong>Don't have an Apple ID or forgot it?</strong> → <strong>Create Apple ID</strong> and follow the prompts.</li>
<li>Turn on <strong>two-factor authentication</strong> if asked — Apple requires it for developer features.</li>
</ol>

!!! tip "Use an Apple ID you'll keep"
    Whatever Apple ID you use here is baked into the app's identity. If you later switch accounts
    you'll have to rebuild from scratch, so pick one you plan to keep.

## Step B — Sign in to the Apple Developer site

<ol class="cx2-steps">
<li>Go to <a href="https://developer.apple.com/account/">developer.apple.com/account</a>.</li>
<li>Sign in with your Apple ID.</li>
<li>Accept the developer agreement if you're prompted to. That's all the free path needs — you can stop here and move on to <a href="xcode.md">Install Xcode</a>.</li>
</ol>

## Step C — (Optional) Enroll in the paid program

Only if you chose the paid route:

<ol class="cx2-steps">
<li>On the same <a href="https://developer.apple.com/account/">Apple Developer</a> page, look for <strong>Enroll</strong> (or go to <a href="https://developer.apple.com/programs/enroll/">developer.apple.com/programs/enroll</a>).</li>
<li>Choose <strong>Individual</strong> (simplest for personal use), pay the $99, and complete the identity check. Apple may ask you to confirm your identity in the <strong>Apple Developer</strong> app on your iPhone.</li>
<li>Enrollment usually approves within a day (sometimes minutes). You'll get an email when it's active.</li>
</ol>

!!! note "You can build while you wait"
    You don't have to wait for paid enrollment to finish — build with the free path now, and
    switch Xcode to your paid team later (it's a one-click change in
    [Build the iPhone app](build-app.md#signing)).

## What you should have now

- [x] An Apple ID with two-factor authentication on.
- [x] You've signed in at least once at developer.apple.com and accepted the agreement.
- [x] (Optional) Paid enrollment started or approved.

Next: [Install Xcode :material-arrow-right:](xcode.md)
