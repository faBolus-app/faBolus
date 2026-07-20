# Advanced (command line)

If you're comfortable in a terminal, you can build and install everything without clicking around
Xcode. This mirrors what CI does. The friendly, step-by-step route is the rest of the
[build guide](index.md) — use this page if you'd rather script it.

!!! warning "Experimental"
    faBolus is in development for experimental use and is not FDA-cleared. See [Safety](../safety.md).

## Prerequisites

- **Xcode** (full app) + an Apple Developer team id.
- **XcodeGen** — `brew install xcodegen` (the `.xcodeproj` is generated from `project.yml`).
- The **Connect IQ Mobile SDK for iOS** placed where `project.yml`'s `ConnectIQ` package points
  (the app links it).
- **JDK 21** — `brew install openjdk@21` — only for PumpX2Kit's oracle tests.
- For the Garmin watch app: the **Connect IQ device SDK** + a developer key (see
  [Build the Garmin remote](garmin-build.md)).

## Clone (siblings)

```sh
mkdir -p ~/faBolus && cd ~/faBolus
git clone --recurse-submodules https://github.com/faBolus-app/PumpX2Kit.git
git clone https://github.com/faBolus-app/faBolus.git
```

`faBolus` consumes `PumpX2Kit` via a local SPM path (`../PumpX2Kit`), so keep them side by
side.

## PumpX2Kit (core + byte-exact oracle tests)

```sh
cd ~/faBolus/PumpX2Kit
git submodule update --init            # vendors the pumpX2 oracle + mbedTLS
./scripts/test.sh                      # builds the cliparser JAR + runs byte-exact tests
```

`scripts/test.sh` works around the Command Line Tools swift-testing rpath issue; the tests use
`import Testing`.

## iOS app (build + install to a device)

```sh
cd ~/faBolus/faBolus
xcodegen generate                      # regenerate the .xcodeproj after adding/removing files

xcodebuild -project faBolus.xcodeproj -scheme faBolus \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAMID> -derivedDataPath build/DD build

xcrun devicectl device list            # find your device UDID
xcrun devicectl device install app --device <UDID> \
  build/DD/Build/Products/Debug-iphoneos/faBolus.app
```

- **`DEVELOPMENT_TEAM`** is your Apple team id (the signing cert's OU). It isn't stored in the
  repo — pass it on the command line. For a compile-only check, add `CODE_SIGNING_ALLOWED=NO` and
  drop the team.
- **App Group** (`group.com.fabolus.app`) is shared by the app, the widget extension,
  and the watch complication. It registers automatically on first signed build; entitlements are
  generated from `project.yml`.
- The **WidgetKit extension**, **Apple Watch app**, and **watch complication** build as targets of
  the same project.

## Garmin watch app (Connect IQ)

The Garmin app is in the separate [faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin) repo:

```sh
cd ~/faBolus/faBolusGarmin
SDK=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/<sdk-version>
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/faBolus.iq -y <developer_key.der> -e -r -w
```

Sideload in the Connect IQ simulator, or upload `bin/faBolus.iq` to the Connect IQ store as a
beta and install from Garmin Connect Mobile. See that repo's README for the venu3s input model and
complication notes.

## Docs site

mkdocs-material, auto-deployed to GitHub Pages by `.github/workflows/docs.yml` on pushes that
touch `docs/`. Local preview: `pip install mkdocs-material && mkdocs serve`.
