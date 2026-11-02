# Open work

What's known to be unfinished and isn't a bug. Unverified pump and CGM behavior is in
[`docs/UNVERIFIED-GUESSES.md`](docs/UNVERIFIED-GUESSES.md); this list is everything else.

| Item | State |
| --- | --- |
| Hardware checks | The unverified guesses each name a check on a real pump, CGM or watch. They're run as hardware is available. |
| Critical Alerts | Not requested from Apple. The alert model carries the level, so a pump without its own screen can use it later. |
| Time Sensitive and data protection | Entitlements a free account can't sign, so `generate-project.sh` leaves them out unless asked (`FABOLUS_TIME_SENSITIVE=1`, `FABOLUS_DATA_PROTECTION=1`). |
| Room left in the types | Mobi, extended boluses and alarm escalation have cases in the types but aren't built. |
| The Connect IQ adapter | Garmin's SDK isn't in the repository, so no CI gate compiles `GarminTransport`; `scripts/check-garmin-transport.sh` compiles it locally. |
| Vendored `ShareClient` | Kept as LoopKit wrote it, so drift against upstream stays visible. |
