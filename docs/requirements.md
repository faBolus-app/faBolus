# What you'll need

Everything to have before you start the [build](build/index.md). The build guide explains each term as
it comes up.

## Hardware

<div class="grid cards" markdown>

- :material-needle:{ .lg .middle } **A Tandem t:slim X2**

    ---

    Either pairing kind works: the 6-digit code of newer firmware or the 16-character code of older
    firmware. faBolus doesn't connect to a Mobi.

- :material-cellphone:{ .lg .middle } **An iPhone**

    ---

    On **iOS 18 or newer**, with a cable to connect it to your Mac. iPad isn't supported.

- :material-laptop:{ .lg .middle } **A Mac**

    ---

    One that runs **Xcode 27.2**, Apple's free app-building tool. The App Store's Xcode page shows the
    macOS version it needs.

- :material-watch:{ .lg .middle } **Optional: a Garmin Venu 3S**

    ---

    The one watch the Garmin app is built for. You also need Garmin's **Garmin Connect** app on the
    iPhone, with the watch paired to it.

</div>

## Accounts

- An **Apple account**. A free one works, but the app stops opening after 7 days until you install it
  again. The Apple Developer Program ($99 a year) makes an install last a year and allows Time Sensitive
  notifications. See [Apple account](build/apple-developer.md).
- A free **GitHub** account is optional. It's only needed for GitHub Desktop sign-in or to send feedback
  through GitHub.
- A free **Garmin** account, only for the watch: it lets you install Garmin's developer tools.

## Glucose

Glucose normally comes from the CGM paired with your pump. As a backup, faBolus can also read:

- **Dexcom Share**: your Dexcom account, with Share turned on in the Dexcom app;
- **Dexcom G6 or G7 directly**: the Dexcom app installed, paired and running on the same iPhone.

See [Backup CGM](setup/cgm.md). faBolus shows glucose in mg/dL only.

## Software you'll install

| Tool | What it's for | Where |
| --- | --- | --- |
| **Xcode 27.2** | Builds the app and puts it on your iPhone | [Xcode and tools](build/xcode.md) |
| **Homebrew** and **XcodeGen** | XcodeGen makes the Xcode project from the repository's `project.yml` | [Xcode and tools](build/xcode.md) |
| **GitHub Desktop** | Downloads the code with buttons instead of commands | [Xcode and tools](build/xcode.md) |
| **Garmin's iOS companion SDK** *(optional)* | Lets the phone app talk to the watch. Without it the app builds with no watch support. | [Put it on your iPhone](build/build-app.md#garmin-sdk) |
| **Garmin's Connect IQ SDK** *(optional)* | Builds the watch app itself | [Garmin watch](build/garmin-build.md) |
| **Java** *(optional)* | Garmin's compiler runs on it | [Garmin watch](build/garmin-build.md#step-3-install-java) |

Got everything? Go to the [build guide :material-arrow-right:](build/index.md).
