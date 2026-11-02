> [!CAUTION]
> faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It is for
> experimental and demonstration use. Not medical advice — check every value against your pump and your
> clinician. If you build or use it, you assume all responsibility.

# faBolus

An iPhone app for the **Tandem t:slim X2**. It shows your glucose and pump status, delivers a bolus
from the phone, and puts glucose on the Lock Screen, in widgets, in a Live Activity and on a
**Garmin Venu 3S** watch, which can also ask the phone for a bolus.

The iPhone is the only thing that talks to the pump. The watch is a remote: it asks, and the phone checks
every request against the same rules as its own bolus screen. The widgets and the Live Activity only
show.

Glucose normally comes through the pump. As a backup, faBolus can read Dexcom Share, or a Dexcom G6 or
G7 directly alongside the Dexcom app, and uses it only while the pump's reading is old or missing. A
reading past its freshness window is shown marked, never as current.

_Built by Zev and Tia in tandem._

## Documentation

The full docs, with a step-by-step build guide that needs no programming, are at **<https://fabolus.org/>**
and in [`docs/`](docs/index.md):

- [Safety](docs/safety.md): read it first.
- [Build it yourself](docs/build/index.md): Apple account, Xcode, then the app on your iPhone, and the
  [Garmin watch](docs/build/garmin-build.md).
- [Pair your pump](docs/setup/pairing.md), [using the app](docs/operate/status.md) and
  [settings](docs/customize/settings.md).

## Build (quick reference)

You need a Mac with Xcode 27.2, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and an Apple account
(free works; paid lasts a year). The [build guide](docs/build/build-app.md) has every step.

```sh
git clone https://github.com/faBolus-app/faBolus.git
cd faBolus
cp LocalConfig.xcconfig.example LocalConfig.xcconfig   # your bundle ID and Team ID
./scripts/generate-project.sh                          # makes faBolus.xcodeproj
open faBolus.xcodeproj                                 # then Run on your iPhone
```

Xcode fetches TandemKit, the pump library, at the revision `Packages/PumpSession` pins. For the watch,
Garmin's iOS companion SDK 1.8.0 goes at `../../vendor/connectiq-companion-app-sdk-ios-1.8.0`; without it
the app builds with no watch support. The watch app itself is
[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin).

## Layout

```text
Packages/       everything that compiles: the pump session, the dose code, alerts, CGM sources,
                the phone↔watch protocol and link, the app's model, and the design system
ios/            the app target, the widgets and Live Activity, and the app's snapshot tests
scripts/        project generation, the quality gates (check.sh), formatting
docs/           the documentation site (MkDocs Material)
```

[ARCHITECTURE.md](ARCHITECTURE.md) explains the packages, [CONTRIBUTING.md](CONTRIBUTING.md) how to work
on them, and [BRANCHES.md](BRANCHES.md) the `main` and `rebuild` branches.

## Feedback

A bug, something confusing or an idea: see [Send feedback](docs/feedback.md), use the
[feedback form](https://github.com/faBolus-app/faBolus/issues/new?labels=feedback&template=feedback.md),
or email [feedback@fabolus.org](mailto:feedback@fabolus.org). For anything urgent about your therapy,
contact your healthcare provider.

## Using it alongside the official Tandem app

The pump pairs with one controller at a time. faBolus and t:connect can both be installed, but switching
between them is a full pairing with a new code from the pump. Some pump settings can only be changed in
t:connect. See [Pair your pump](docs/setup/pairing.md#fabolus-and-tconnect).

## Acknowledgments

faBolus is built on **[pumpX2](https://github.com/jwoglom/pumpx2)** by **James Woglom
([@jwoglom](https://github.com/jwoglom))**. His reverse-engineering of the Tandem pump's Bluetooth
protocol is the foundation of this project. [TandemKit](https://github.com/faBolus-app/TandemKit) is a
Swift port of it, validated byte for byte against pumpX2's `cliparser` oracle. faBolus would not exist
without it. faBolus is an independent reimplementation, not a fork of, affiliated with, or endorsed by
pumpX2 or controlX2.

It also draws on **[LoopKit](https://github.com/LoopKit)** and **[Loop](https://github.com/LoopKit/Loop)**:
the Dexcom readers and the Dexcom Share client are copied from LoopKit's MIT code, and parts of the design
and the docs take inspiration from Loop and [LoopDocs](https://loopkit.github.io/loopdocs/). Full
attributions are in [NOTICE.md](NOTICE.md) and [THIRD_PARTY.md](THIRD_PARTY.md).

> [!NOTE]
> faBolus is an independent, open-source project. It is not affiliated with Tandem Diabetes Care or
> Dexcom.

## License and trademark

The code is MIT-licensed (see [LICENSE](LICENSE)). **faBolus™** is a trademark of Zev Granowitz; the
license covers the source code, not the name, logo or branding. Forks are welcome under the MIT terms;
please don't use the faBolus name in a way that implies your fork is the official project. See
[NOTICE.md](NOTICE.md).
