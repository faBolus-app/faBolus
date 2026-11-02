<!--
faBolus is experimental software controlling an insulin pump.
Fill in what applies; delete what doesn't. See CONTRIBUTING.md and BRANCHES.md.
-->

## What & why

<!-- One or two sentences. What changes, and the problem it solves. -->

## Safety

- [ ] Does **not** weaken a safety interlock (confirmation, the pump's limits, single-flight, the
      idempotency ledger, fail-closed transport gating), and adds no dose path around the composer,
      the access policy, TandemKit's `WritePolicy` and the signed message
- [ ] No glucose value reaches a display layer without a source timestamp; no client-derived trend
      arrow; no locally-invented IOB or therapy parameter
- [ ] If this touches dosing guidance, thresholds, or automation copy: the clinical-review gate
      (BRANCHES.md) is noted — such work does not reach anyone but the developer until that review lands

## Contract

- [ ] Did **not** touch `Packages/RemoteProtocol/contract/`
- [ ] — or did, and: rewrote the golden fixtures (`UPDATE_CONTRACT=1` on RemoteProtocol's tests), and
      updated faBolusGarmin's `contract/PIN` with its `scripts/sync-contract.sh` in a linked PR whose
      `./scripts/check.sh` passes

## Verification

<!-- Paste the commands you ran and their result. CI's Xcode is stricter than a typical local one, so
     "builds locally" is necessary but not sufficient — say what you expect CI to confirm. -->

- [ ] `./scripts/check.sh` passes
- [ ] Hardware-tested vs. compile-only noted

## Cross-repo

- [ ] N/A — single repo
- [ ] Touches the contract, a shared constant or TandemKit → sibling PR(s) linked, with the pin
      (`contract/PIN`, or the TandemKit release in the packages' `Package.swift`) at the sibling's release
