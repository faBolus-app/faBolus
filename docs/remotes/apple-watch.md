# Apple Watch remote

A thin Loop-style remote. **The watch never touches the pump** — `PumpX2Kit` runs on the
iPhone; the watch relays commands over WatchConnectivity.

## Use
- The watch glance shows glucose + trend, Active Insulin, and iPhone reachability.
- Tap **Bolus**, dial units with the **Digital Crown**, and tap **Request on iPhone**.
- The watch shows *"Confirm on iPhone"*; deliver only completes after you confirm on the phone
  (**double confirmation**).
- If the iPhone is out of range, the request is queued/failed cleanly — never silently
  delivered.

## Contract
Phone↔watch messages follow [`schema/command.schema.json`](../architecture.md): a tiny JSON
contract (`kind`, `requestId`, `units`, `confirmToken`, `status`, …). The Swift mirror is
`Shared/RemoteCommand.swift`; transport is `Shared/RemoteLink.swift`.
