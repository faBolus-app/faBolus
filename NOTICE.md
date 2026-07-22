# Attributions

faBolus is an independent, open-source project, licensed under the MIT License (see `LICENSE`).

## The faBolus™ name

**faBolus™** is a trademark of Tia Geri. The MIT License covers this project's **source code**; it
does not grant any right to use the "faBolus" name, logo, or branding. You are free to fork and
reuse the code under the MIT terms, but please do not use the faBolus name in a way that suggests
your fork is the official project or is endorsed by it.

It is built on the Tandem pump Bluetooth protocol as reverse-engineered by the
**[pumpX2](https://github.com/jwoglom/pumpx2)** project (© James Woglom, MIT License). faBolus is an
independent reimplementation for iPhone / Apple Watch / Garmin; it is **not** a fork of, affiliated
with, or endorsed by pumpX2/controlX2.

The protocol/auth/Bluetooth core lives in the separate **PumpX2Kit** package, which vendors
**Mbed TLS** (Apache-2.0 OR GPL-2.0) for its EC-JPAKE implementation — see PumpX2Kit's own `NOTICE`
for that attribution.

## G7SensorKit (Dexcom G7 / ONE+ decoding)

The Dexcom G7 / ONE+ BLE message decoders in `Packages/G7SensorKit` are vendored from
**[LoopKit/G7SensorKit](https://github.com/LoopKit/G7SensorKit)** (© 2022 LoopKit Authors; several
files originate in xDripG5 / CGMBLEKit, © 2015–2016 Nathan Racklyeft), used under the MIT License.
LoopKit-specific coupling has been removed and the decoders are passive/read-only. The reproduced
license and copyright are in `Packages/G7SensorKit/LICENSE`. The independent CGM seam that consumes
them is modeled on LoopKit's `CGMManager` design.
## Loop / LoopDocs (design + documentation)

faBolus's visual design draws inspiration from the **[Loop](https://github.com/LoopKit/Loop)** app,
and portions of this project's documentation are adapted from
**[LoopDocs](https://loopkit.github.io/loopdocs/)**. faBolus is an independent project and is not
affiliated with, or endorsed by, the Loop / LoopKit projects.

Not affiliated with, endorsed by, or a product of **Tandem Diabetes Care** or **Dexcom**. Tandem,
t:slim X2, Mobi, and Dexcom are trademarks of their respective owners.
