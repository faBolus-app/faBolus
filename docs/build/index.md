# Build it yourself

faBolus isn't in the App Store. You build it on your Mac and Xcode puts it on your iPhone. You don't
need to know how to code: every step is written out, and the few Terminal commands are given word for
word.

Go one page at a time, in order. If a step doesn't work, [Troubleshooting](../troubleshoot.md) covers the
common problems.

!!! warning "Read Safety first"
    faBolus can tell your pump to deliver insulin, and it is not a medical device or FDA-cleared. Read
    [Safety](../safety.md) before you build it.

## What "building" means

The app's source code is a recipe. **Xcode**, Apple's free app-building tool, turns it into the app and
installs it on your iPhone over a cable. You build once; after that you re-run the last step from time to
time so the app doesn't expire (see [Keeping it running and updating](updating.md)).

## The steps

<div class="grid cards" markdown>

- :material-account-key:{ .lg .middle } **1 · Apple account**

    ---

    Sign in with an Apple account so Apple lets you install your own app.

    [:octicons-arrow-right-24: Apple account](apple-developer.md)

- :material-download:{ .lg .middle } **2 · Xcode and tools**

    ---

    Install Xcode, GitHub Desktop and one small command-line tool.

    [:octicons-arrow-right-24: Xcode and tools](xcode.md)

- :material-cellphone-arrow-down:{ .lg .middle } **3 · Put it on your iPhone**

    ---

    Download the code, set your details, and press Run.

    [:octicons-arrow-right-24: Build the app](build-app.md)

- :material-watch-variant:{ .lg .middle } **4 · Garmin watch (optional)**

    ---

    Build the watch app for a Garmin Venu 3S and connect it to the phone. You can add it later.

    [:octicons-arrow-right-24: Garmin watch](garmin-build.md)

</div>

Then [pair your pump](../setup/pairing.md), and optionally set up a [backup CGM](../setup/cgm.md).

## Free or paid Apple account

| | Free Apple account | Apple Developer Program ($99 a year) |
| --- | --- | --- |
| The app keeps opening for | **7 days**, then you install it again from the Mac | **1 year** |
| Time Sensitive notifications (break through Focus) | No: they arrive as normal notifications | Yes, with one extra setting |
| Everything else | Works | Works |

Start free if you're trying it out. You can switch to a paid account later without starting over.

## How long it takes

About an hour or two the first time, mostly waiting for Xcode to download. Updating later takes a few
minutes.

<div class="cx2-check" markdown>
**Ready?** Start with [Step 1 · Apple account](apple-developer.md).
</div>
