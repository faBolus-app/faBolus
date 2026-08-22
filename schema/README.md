# schema

Single source of truth for the phone↔remote command contract: `command.schema.json`.

The iOS host (`ios/faBolus`, via `Packages/faBolusCore/Sources/faBolusCore/RemoteCommand.swift`) and
the Monkey C Garmin remote (in the separate
[faBolusGarmin](https://github.com/faBolus-app/faBolusGarmin) repo, via its `RemoteComm`) both
generate and validate messages against this file so the two sides never drift. It's a small JSON
contract — `kind`, `requestId`, `units`, `carbsGrams`, `bgMgdl`, `confirmToken`, `status`,
`deliveredUnits`, and the status fields the remote displays.

See [How it works → The command contract](../docs/architecture.md#the-command-contract).
