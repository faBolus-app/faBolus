# FAQ

**Is this Loop?**
No. ControlX2iOS borrows Loop's *visual language and terminology* for familiarity, but it is a
**manual remote-bolus + status viewer**, not an automated closed-loop system. It is not
affiliated with Loop/LoopKit.

**Is this the Tandem app or controlX2?**
No. It's an independent reimplementation for iOS, inspired by the naming of jwoglom's Android
`controlX2` and built on the `pumpX2` protocol work. Not affiliated with or endorsed by either,
nor by Tandem.

**Can I use this to dose insulin?**
No. It is a **bench proof-of-concept** — saline, on a scale, never on a body. See
[Safety](safety.md).

**Which pumps?**
t:slim X2 and Mobi, on a firmware version we've pinned and tested. The protocol can break on a
pump firmware update.

**Does the watch/Garmin talk to the pump directly?**
No. The iPhone owns the connection; remotes relay commands to it (with double confirmation). A
standalone Apple Watch is a later goal; standalone Garmin is a separate future project.

**How do you know the protocol bytes are right?**
Every outgoing message is tested **byte-for-byte** against the pumpX2 `cliparser` oracle, in CI.

**Carb-based bolus?**
A follow-on: a carbs/BG entry that drives the pump's bolus calculator to recommend units,
delivered through the same validated path. The units-only path is the safe default.
