# REINTEGRATION.md — dev/phone-remote

## Feature preserved

The iPhone-to-iPhone peer remote (Phase 3, REMOTE-02): `PeerRemoteHost`,
`PhoneRemoteClientModel`, `RemotePeerPolicyStore`, and the `Remote*View` UI surfaces, gated behind
`PHONE_PEER` / `PHONE_PEER_KEEP` fences (already authored, Phase 0).

**Important boundary:** the shared `PhoneRemoteHost.swift` core is used by more than just this
surface and must NEVER be included in this branch's "what to restore" list — only the
peer-specific files (`PeerRemoteHost`, `PhoneRemoteClientModel`, `RemotePeerPolicyStore`,
`Remote*View`) belong to this branch's removal/reintegration scope.

## State at removal

Not yet touched — Phase 3 (REMOTE-02) has not executed as of this writing. This branch carries the
full pre-narrow tree, identical to `pre-narrow/2026-08-20`; nothing has diverged here yet. This
REINTEGRATION.md is being authored ahead of Phase 3 per CLEAN-02.

## Reintegration steps

The `PHONE_PEER`/`PHONE_PEER_KEEP` gate already distinguishes peer-only files from the shared
`PhoneRemoteHost` core, so reintegration is expected to be moderate complexity — largely a file-list
restoration, but with one boundary check that must not be skipped:

1. Restore the peer-specific files only: `PeerRemoteHost`, `PhoneRemoteClientModel`,
   `RemotePeerPolicyStore`, `Remote*View`. Do NOT restore or modify `PhoneRemoteHost.swift` as part
   of this reintegration — it is shared, lives on `main` regardless of this feature's state, and
   any change to it belongs to a different surface's work.
2. Restore the `PHONE_PEER`/`PHONE_PEER_KEEP` `project.yml`/`generate-project.sh` fences (or the
   equivalent shape Phase 3 actually used, if it diverged from the pre-authored gate names — check
   at reintegration time).
3. **Re-verify the shared-core boundary test still passes** after restoration — confirm no peer
   file re-acquired an accidental dependency edge into `PhoneRemoteHost.swift` internals beyond its
   public shared-core interface.
4. Re-run the full exit gate (`docs/NARROW-MAIN-GATES.md`); these files are not part of
   `DOSE_PATHS`, so no dose-set stub/un-stub is expected, but re-verify against Phase 3's actual
   removal shape when it lands.
