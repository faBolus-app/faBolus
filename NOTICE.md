# Attributions

faBolus is an independent, open-source project, licensed under the MIT License (see `LICENSE`).

It is built on the Tandem pump Bluetooth protocol as reverse-engineered by the
**[pumpX2](https://github.com/jwoglom/pumpx2)** project (© James Woglom, MIT License). faBolus is an
independent reimplementation for iPhone / Apple Watch / Garmin; it is **not** a fork of, affiliated
with, or endorsed by pumpX2/controlX2.

The protocol/auth/Bluetooth core lives in the separate **PumpX2Kit** package, which vendors
**Mbed TLS** (Apache-2.0 OR GPL-2.0) for its EC-JPAKE implementation — see PumpX2Kit's own `NOTICE`
for that attribution.

## Loop / LoopDocs (design + documentation)

faBolus's visual design draws inspiration from the **[Loop](https://github.com/LoopKit/Loop)** app,
and portions of this project's documentation are adapted from
**[LoopDocs](https://loopkit.github.io/loopdocs/)**. faBolus is an independent project and is not
affiliated with, or endorsed by, the Loop / LoopKit projects.

Not affiliated with, endorsed by, or a product of **Tandem Diabetes Care** or **Dexcom**. Tandem,
t:slim X2, Mobi, and Dexcom are trademarks of their respective owners.
