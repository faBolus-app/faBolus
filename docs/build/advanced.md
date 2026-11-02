# Command line

The same build as the step-by-step guide, for people comfortable in a terminal.

## Prerequisites

- Xcode 27.2 and an Apple team.
- XcodeGen (`brew install xcodegen`).
- Optional, for the watch: Garmin's iOS companion SDK 1.8.0, unzipped at
  `../../vendor/connectiq-companion-app-sdk-ios-1.8.0` relative to the faBolus checkout, the Connect IQ
  SDK (9.2.0) with the Venu 3S device, and a Java runtime for `monkeyc`.

## The phone app

```sh
mkdir -p ~/Developer/faBolus && cd ~/Developer/faBolus
git clone https://github.com/faBolus-app/faBolus.git
cd faBolus
cp LocalConfig.xcconfig.example LocalConfig.xcconfig   # set APP_BUNDLE_ID and DEVELOPMENT_TEAM
./scripts/generate-project.sh

xcodebuild -project faBolus.xcodeproj -scheme faBolus -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build/DD build

xcrun devicectl list devices
xcrun devicectl device install app --device <device id> build/DD/Build/Products/Debug-iphoneos/faBolus.app
```

TandemKit isn't cloned: `Packages/PumpSession` and `Packages/PhoneApp` pin the same release, and Xcode
fetches it. To build
against a local TandemKit checkout, see [CONTRIBUTING.md](https://github.com/faBolus-app/faBolus/blob/main/CONTRIBUTING.md).

### What `generate-project.sh` settles

It writes `project.generated.yml` (git-ignored) from `project.yml` and generates `faBolus.xcodeproj`
from it. Plain `xcodegen generate` would need everything below present.

| Variable | Default | Effect |
| --- | --- | --- |
| `FABOLUS_GARMIN` | on when the SDK folder exists | `0` leaves out the Connect IQ package, the adapter and the `GARMIN` compile flag; `1` requires the SDK. |
| `FABOLUS_TIME_SENSITIVE` | off | `1` keeps the Time Sensitive notification entitlement. Needs a paid account. |
| `FABOLUS_DATA_PROTECTION` | off | `1` keeps the default data-protection entitlement (`NSFileProtectionCompleteUntilFirstUserAuthentication`, iOS's default class anyway). Needs the capability on the App ID. |

It also writes `ios/faBolus/Generated/AppRevision.swift`, the commit the build came from, shown in
**Settings → About & help**.

### Your settings

`LocalConfig.xcconfig` (git-ignored) overrides `Config.xcconfig`:

| Setting | What it is |
| --- | --- |
| `APP_BUNDLE_ID` | Unique to you. The widgets' ID, the App Group (`group.<id>`) and the URL type names derive from it. |
| `DEVELOPMENT_TEAM` | Your Team ID, or empty to choose in Xcode. |
| `GARMIN_BETA_APP_ID` | The Connect IQ app the phone talks to. Defaults to the watch app's own ID in `manifest.xml`; faBolusGarmin's `beta-build.sh` sets it to your private beta's. |

## The watch app

```sh
cd ~/Developer/faBolus
git clone https://github.com/faBolus-app/faBolusGarmin.git
cd faBolusGarmin
./scripts/stamp-revision.sh
SDK="$(ls -d "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/"connectiq-sdk-* | sort -V | tail -1)"
"$SDK/bin/monkeyc" -f monkey.jungle -d venu3s -y <developer_key.der> -o bin/faBolus.prg
```

Copy `bin/faBolus.prg` to `GARMIN/APPS` on the watch over USB (MTP), or publish a private beta with
`scripts/beta-build.sh` (see [Garmin watch](garmin-build.md#step-6b-or-publish-a-private-beta)).
`CIQ_KEY=../developer_key.der ./scripts/build-and-test.sh` compiles the app and test jungles, fails on any
compiler warning, and runs the unit suite in the simulator; its key defaults to `./developer_key.der`.

## The docs site

The site is MkDocs Material, published from `main` by `.github/workflows/docs.yml`. To preview it:

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements-docs.txt
.venv/bin/mkdocs serve
```
