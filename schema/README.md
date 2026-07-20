# schema

Single source of truth for the phone↔remote command contract: `command.schema.json`.

The Swift host (`ios/`, `watch/`, via `Shared/RemoteCommand.swift`) and the Monkey C Garmin remote
(in the separate [PumpX2Garmin](https://github.com/zgranowitz/PumpX2Garmin) repo, via its
`RemoteComm`) both generate and validate messages against this file so the sides never drift. It's
a small JSON contract — `kind`, `requestId`, `units`, `carbsGrams`, `bgMgdl`, `confirmToken`,
`status`, `deliveredUnits`, and the status fields remotes display.

See [How it works → The command contract](../docs/architecture.md#the-command-contract).
