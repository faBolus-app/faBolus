# Build it yourself

You do **not** need to know how to code. If you can follow a recipe, you can do this. This guide
holds your hand through every step — from making an Apple account to seeing the app on your own
iPhone.

Take it slowly, one page at a time, in order. If a step doesn't work, don't worry — the
[Troubleshooting](../troubleshoot.md) page covers the common snags.

!!! warning "Experimental — in development"
    faBolus can tell an insulin pump to deliver insulin, and it is **not FDA-cleared**. It's an
    open-source project for experimental use — you assume all responsibility. Please read
    [Safety](../safety.md) before you build anything.

## What "building" means (in plain words)

This app isn't in the App Store. Instead, you copy its recipe (the "source code") onto a **Mac**,
and a free Apple program called **Xcode** turns that recipe into the actual app and puts it on
your iPhone. That's "building."

You do it once. Every so often you'll redo the last step to keep the app from expiring — that
takes about a minute (see [Keeping the app running](updating.md)).

!!! tip "You won't be typing commands (much)"
    This guide is click-and-point wherever possible: you'll use free apps like **GitHub Desktop**
    and **Xcode**, and **Finder** to move a file. There's just **one** short step that uses the
    Terminal, and it's written out word-for-word with plain-English explanations. Anything meant
    only for advanced users is tucked inside a *"click to open"* box you can ignore.

## The whole process, start to finish

Five short chapters. The first three get the app on your iPhone; the last two are optional
watches. Both watches are optional at build time — the phone app builds and runs fine on its own,
and you can add either one later.

<div class="grid cards" markdown>

-   :material-account-key:{ .lg .middle } **1 · Apple account**

    ---

    Sign in with an Apple ID so you're allowed to put your own app on your phone.

    [:octicons-arrow-right-24: Start here](apple-developer.md)

-   :material-download:{ .lg .middle } **2 · Install Xcode**

    ---

    Get Apple's free app-building tool from the Mac App Store.

    [:octicons-arrow-right-24: Install Xcode](xcode.md)

-   :material-cellphone-arrow-down:{ .lg .middle } **3 · Put the app on your iPhone**

    ---

    Download the code and press one button to install it.

    [:octicons-arrow-right-24: Build the app](build-app.md)

-   :material-watch:{ .lg .middle } **4 · Add the Apple Watch (optional)**

    ---

    Install the matching watch app.

    [:octicons-arrow-right-24: Add the watch](apple-watch-build.md)

-   :material-watch-variant:{ .lg .middle } **5 · Add a Garmin (optional)**

    ---

    Build the Garmin remote for a Garmin watch.

    [:octicons-arrow-right-24: Build for Garmin](garmin-build.md)

</div>

## Do you have everything?

You'll want all of these before you start (details on [What you'll need](../requirements.md)):

- [x] A **Mac** computer (any recent one).
- [x] An **iPhone** (iOS 17 or newer) and a cable to plug it into the Mac.
- [x] An **Apple ID** — the same email/password you use for the App Store.
- [x] A **Tandem t:slim X2 or Mobi** pump.
- [x] *Optional:* an **Apple Watch** or a **Garmin venu3s**.

## How much time and money?

| | Free Apple account | Paid account ($99/year) |
| --- | --- | --- |
| Time for the first build | About 1–2 hours, mostly waiting on downloads | About 1–2 hours |
| App keeps working for | **7 days**, then you redo one step | **1 year** |
| Widgets & watch app | Can be fiddly | Work smoothly |

!!! tip "Which should I pick?"
    **Start free** — it costs nothing and works. If you end up using the app regularly, the
    $99/year account means you only re-install once a year instead of weekly, and the widgets and
    watch app behave better. You can switch to paid later without redoing anything.

<div class="cx2-check" markdown>
**Ready?** Go to [Step 1 · Apple account](apple-developer.md). Just follow each page in order and
you'll be fine.
</div>
