# Build it yourself

You don't need to be a programmer to build ControlX2iOS. If you can follow a recipe, you can do
this. This guide walks you through every step — from creating an Apple account to seeing the app
running on your own iPhone — in plain language, the same way the
[LoopDocs](https://loopkit.github.io/loopdocs/) build guide does for Loop.

!!! danger "Before you build anything, read the safety rules"
    ControlX2iOS is a **bench proof-of-concept**. It must only ever be connected to a dedicated
    **test pump dispensing saline into a container on a scale — never a pump on a body.** If you
    haven't yet, read [Safety first](../safety.md) and [What you'll need](../requirements.md).

## What "building" means

Apps like this one aren't in the App Store — you assemble ("build") the app from its source
code on a Mac and install it onto your own devices. Apple lets anyone do this for their own use.
The tool that does the building is **Xcode**, Apple's free app for making apps.

You'll do it once, and then re-install every so often to keep it from expiring (more on that in
[Keeping the app running](updating.md)).

## The five steps

<div class="grid cards" markdown>

-   **1 · Apple ID & Developer account**

    ---

    Get the Apple account that lets you install your own apps. A **free** account works; a
    **paid** one ($99/year) means you rebuild far less often.

    [:octicons-arrow-right-24: Start](apple-developer.md)

-   **2 · Install Xcode**

    ---

    Install Apple's free app-building tool from the Mac App Store and let it finish its
    first-run setup.

    [:octicons-arrow-right-24: Install](xcode.md)

-   **3 · Build the iPhone app**

    ---

    Download the code, generate the project, sign it with your account, and run it on your
    iPhone.

    [:octicons-arrow-right-24: Build the app](build-app.md)

-   **4 · Add the Apple Watch app**

    ---

    Optional: install the matching Apple Watch remote alongside the phone app.

    [:octicons-arrow-right-24: Add the watch](apple-watch-build.md)

-   **5 · Build the Garmin remote**

    ---

    Optional: build the Garmin (Connect IQ) remote — it lives in the separate **PumpX2Garmin**
    repo and pairs to this app.

    [:octicons-arrow-right-24: Build for Garmin](garmin-build.md)

</div>

!!! tip "Prefer the command line?"
    If you're comfortable in a terminal, there's a faster [command-line build](advanced.md) using
    `xcodebuild` / `devicectl` (and the `monkeyc` Garmin build). The step-by-step Xcode path below
    is the friendlier route.

## Before you start: a quick check

Make sure you have all of these. Details are in [What you'll need](../requirements.md).

- [x] A **Mac** running a recent macOS (needed to run Xcode).
- [x] An **iPhone** on iOS 17 or later, plus a cable to connect it to the Mac.
- [x] An **Apple ID** (you'll set up the developer side in step 1).
- [x] A **dedicated saline test pump** — a Tandem t:slim X2 or Mobi you will *only* ever use on
      the bench with saline.
- [x] Optional: an **Apple Watch** (watchOS 10+) and/or a **Garmin venu3s** for the remotes.

## How long, and how much?

| | Free Apple account | Paid Apple Developer ($99/yr) |
| --- | --- | --- |
| First build | ~1–2 hours (mostly downloads) | ~1–2 hours |
| App expires after | **7 days** (rebuild weekly) | **1 year** |
| Apple Watch app | Supported | Supported |
| Widgets | Limited (extensions can be finicky on free accounts) | Fully supported |

!!! tip "Recommended: the paid account"
    The $99/year Apple Developer Program isn't required, but rebuilding every 7 days gets old
    fast, and the widgets/watch extensions are more reliable with it. Most people who use apps
    like this settle on the paid account. Either way, **start with the free path if you're just
    trying it out** — you can upgrade later without losing anything.

Ready? Start with [Apple ID & Developer account :material-arrow-right:](apple-developer.md).
