# Building & installing

Everything here is a **bench proof-of-concept** — saline only, never on a body. You need a Mac.

## Prerequisites
- **Xcode** (full app, not just Command Line Tools) + a **paid Apple Developer** account.
- **[XcodeGen](https://github.com/yonasstephen/xcodegen)** (`brew install xcodegen`) — the
  `.xcodeproj` is generated from `project.yml` (and is git-ignored).
- **Connect IQ SDK** (Garmin) + a developer key, for the Garmin remote.
- **JDK 21** (`brew install openjdk@21`) — only for building/running the pumpX2 `cliparser`
  oracle used by PumpX2Kit's tests.

## Repositories
- **[PumpX2Kit](https://github.com/zgranowitz/PumpX2Kit)** — Swift protocol/auth/BLE core (SPM).
- **ControlX2iOS** (this repo) — iOS app + Apple Watch + Garmin remote. Consumes PumpX2Kit via a
  local SPM path (`../PumpX2Kit`), so clone them as siblings.

## PumpX2Kit (core + oracle tests)
```
cd PumpX2Kit
git submodule update --init            # vendors the pumpX2 oracle source
./scripts/test.sh                      # builds the cliparser JAR + runs byte-exact tests
```
`scripts/test.sh` works around the CLT swift-testing rpath issue; tests use `import Testing`.

## iOS app (device install)
```
cd ControlX2iOS
xcodegen generate                      # regenerate the .xcodeproj after adding/removing files
xcodebuild -project ControlX2.xcodeproj -scheme ControlX2 \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAMID> -derivedDataPath build/DD build
xcrun devicectl device list            # find your device UDID
xcrun devicectl device install app --device <UDID> build/DD/Build/Products/Debug-iphoneos/ControlX2.app
```
- **DEVELOPMENT_TEAM** is your Apple team id (the cert's OU). Not stored in the repo — pass it on
  the CLI. Compile-only check: add `CODE_SIGNING_ALLOWED=NO` and drop the team.
- **App Group** (`group.com.zgranowitz.controlx2`) is shared by the app + the widget extension.
  It must be registered once in your developer account (open the project in Xcode → each target →
  Signing & Capabilities → set Team; the App Group registers automatically). Entitlements are
  generated from `project.yml`.
- The **WidgetKit extension** and **Apple Watch** app build as targets of the same project.

## Garmin remote (Connect IQ)
```
cd ControlX2iOS/garmin
SDK=~/Library/Application\ Support/Garmin/ConnectIQ/Sdks/<sdk-version>
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/ControlX2.iq -y <developer_key.der> -e -r -w
```
Sideload the `.prg` in the Connect IQ simulator, or upload `bin/ControlX2.iq` to the Connect IQ
store as a beta and install it on the watch from Garmin Connect Mobile. See
[`garmin/README.md`](https://github.com/zgranowitz/ControlX2iOS/blob/master/garmin/README.md) for
the venu3s input model and complication notes.

## Docs site (this site)
mkdocs-material, auto-deployed to GitHub Pages by `.github/workflows/docs.yml` on pushes to
`docs/`. Local preview: `pip install mkdocs-material && mkdocs serve`.
