# Advanced (command line)

If you're comfortable in a terminal, you can build and install everything without clicking around
Xcode. This mirrors what CI does. The friendly, step-by-step route is the rest of the
[build guide](index.md) — use this page if you'd rather script it.

!!! warning "Experimental"
    faBolus is in development for experimental use and is not FDA-cleared. See [Safety](../safety.md).

## Prerequisites

- **Xcode 16+** (full app) + an Apple Developer team id.
- **XcodeGen** — `brew install xcodegen` (the `.xcodeproj` is generated from `project.yml` via
  `./scripts/generate-project.sh`).
- *Optional:* the **Connect IQ Mobile SDK for iOS**, placed where `project.yml`'s `ConnectIQ`
  package points (default `../../vendor/connectiq-companion-app-sdk-ios-1.8.0`). Only needed for the
  Garmin remote — if it's absent, `generate-project.sh` auto-detects that and builds without Garmin.
- **JDK 21** — `brew install openjdk@21` — only for PumpX2Kit's oracle tests.
- *Optional:* for the Garmin watch app, the **Connect IQ device SDK** + a developer key (see
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
./scripts/generate-project.sh          # regenerate the .xcodeproj (auto-detects Garmin SDK)

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

### Choosing what's included (env flags)

`./scripts/generate-project.sh` reads two environment variables to decide what to bake into the
generated `.xcodeproj`. When either optional component is dropped, its package/dependency and its
compile flag are stripped from a derived spec (`project.generated.yml`), and the app shows a note in
its **Remotes & devices** settings section explaining what was left out and how to add it back
(rebuild with the piece present).

| Variable | Default | Effect |
| --- | --- | --- |
| `FABOLUS_WATCH` | `1` (included) | `FABOLUS_WATCH=0` builds the phone app **without** embedding the Apple Watch app (drops the embed dependency + `WATCH_EMBEDDED` flag). |
| `FABOLUS_GARMIN` | auto-detected | Unset: Garmin is included only if the Connect IQ SDK is present at the vendored path. `FABOLUS_GARMIN=1` / `=0` forces Garmin on/off, overriding auto-detection (`=1` requires the SDK; `=0` drops the ConnectIQ package + `GARMIN` flag). |

```sh
# phone app only — no watch, no Garmin
FABOLUS_WATCH=0 FABOLUS_GARMIN=0 ./scripts/generate-project.sh
```

!!! note "Plain `xcodegen generate` includes everything"
    Running `xcodegen generate` directly (instead of the script) still works, but always builds the
    full project — watch embedded and Garmin linked — so it requires the Connect IQ SDK to be
    present. Use the script if you want the optional-component handling.

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
