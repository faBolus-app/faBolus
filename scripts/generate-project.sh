#!/usr/bin/env bash
#
# Generate faBolus.xcodeproj, making Garmin (Connect IQ SDK) OPTIONAL so the app compiles/installs
# for users who don't have the SDK. See the numbered notes below for every other opt-in/opt-out gate.
#
#   - Garmin: auto-detected. If the Connect IQ SDK vendor folder is absent, the ConnectIQ package +
#     dependency are removed from the spec and the GARMIN compile flag is dropped, so nothing links or
#     imports the SDK. Override with FABOLUS_GARMIN=0/1.
#   - Apple Watch (as remote) + Apple-Watch-as-host/direct-to-pump: REMOVED from narrow main (Phase 3,
#     03-03, REMOTE-03/REMOTE-04, delete-on-main) — there is no Watch target left to gate. Preserved on
#     dev/watch-remote (app + complication) and dev/watch-host (the direct-pump subtree); see their
#     REINTEGRATION.md to restore the retired watch-embed / watch-direct-pump compile-flag cascade.
#   - On-watch eating detection (Phase 5, step 6): retired along with the Watch target above — there
#     is no watch build left for it to run on. The Garmin eating path (phone-side inference) is
#     unaffected and works regardless.
#   - Data Protection (§13/F1 at-rest): the `com.apple.developer.default-data-protection` entitlement
#     defaults OFF because it needs the Data Protection capability provisioned on the App ID (a paid /
#     portal-enabled account); automatic signing on an account without it can't build the device app.
#     When off, the tagged entitlement line is stripped from the generated spec for BOTH iOS targets so
#     xcodegen omits it from the .entitlements files it writes, and an unmodified clone signs. It is a
#     functional no-op on-device — the value (NSFileProtectionCompleteUntilFirstUserAuthentication) is
#     already iOS's default level. Enable on a provisioned account with FABOLUS_DATA_PROTECTION=1.
#   - TandemKit (backend pump-protocol stack, §1.3 version-pin): consumed by pinned `revision:` by
#     default (reproducible across clones/CI — D-01). Set FABOLUS_TANDEM_LOCAL=1 to swap in the
#     sibling checkout (../TandemKit) for day-to-day co-development; never for a build you keep.
#
# When a feature is off, the app shows a note where its pairing/setup would be, explaining it wasn't
# included at build time. Re-run with the SDK present to restore it (the watch surface is a
# permanent delete-on-main removal, not a build-time toggle — see dev/watch-remote/dev/watch-host).
#
# Requires: xcodegen. Writes a derived spec (project.generated.yml, gitignored) and generates from it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SDK_DIR="$REPO/../../vendor/connectiq-companion-app-sdk-ios-1.8.0"
if [ -n "${FABOLUS_GARMIN:-}" ]; then
  GARMIN="$FABOLUS_GARMIN"
else
  GARMIN=1; [ -d "$SDK_DIR" ] || GARMIN=0
fi
# Phase 3 (03-03, REMOTE-03/REMOTE-04): the Apple-Watch-as-remote app + complication and the
# Apple-Watch-as-host/direct-to-pump subtree are permanently removed from narrow main (delete-on-main,
# D-01) — there is no watch surface left to gate, on-device eating detection has no watch build to run
# on, and the watch's direct-to-pump path (constraint-C9 bench-only concern) no longer exists here at
# all. No variable, no strip_block, no compile flag for any of this remains. Preserved on
# dev/watch-remote (app + complication) and dev/watch-host (direct-pump subtree, REMOTE-04).

# Phase 4 (04-01, NUDGE-01): the faBolusNudge advisory SDK (Smart Assist: on-device eating detection +
# meal-detection intelligence) is permanently removed from narrow main (delete-on-main, D-01/D-03) —
# there is no package/product/compile-flag cascade left to auto-detect or gate. Relying on the old
# `git ls-remote` reachability probe was itself the false-pass hazard D-03 exists to remove (a machine
# with repo access would silently resolve NUDGE=1). Preserved on dev/nudge; see its REINTEGRATION.md.
# Automatic iCloud settings sync (NSUbiquitousKeyValueStore) defaults OFF: it needs a paid Apple
# Developer account + the iCloud capability, which would break the free-account build. When off, the
# entitlement block and the FABOLUS_ICLOUD compile flag are stripped so the no-op stub compiles and an
# unmodified clone signs on a free account. Enable on a paid account with FABOLUS_ICLOUD=1.
ICLOUD="${FABOLUS_ICLOUD:-0}"
# Apple Health (HealthKit) import/export (Phase 09.23, D-10/D-13) was removed from `main` entirely
# in Phase 5 (HEALTH-01) — the whole HealthKit surface, the entitlement, the usage strings, and the
# FABOLUS_HEALTHKIT compile flag are all deleted, not merely default-off. See dev/healthkit's
# REINTEGRATION.md.
# Phase 09.5 D-02: the experimental Control-IQ+ temp-rate overturn (see AppModel.swift setTempBasal).
# Defaults OFF: the `#if !FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL` precondition compiles into every normal
# build (default/shipping behavior byte-identical — CIQ-off is still required to set a temp rate). When
# off, the compile flag is dropped from the generated spec so the experimental overturn compiles out
# entirely. Enable ONLY for a deliberate local/bench build with FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL=1 —
# never for a build a real user runs, and never in CI.
TEMPRATE_CIQ_EXPERIMENTAL="${FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL:-0}"
# Data Protection (§13/F1) at-rest entitlement defaults OFF: com.apple.developer.default-data-protection
# needs the Data Protection capability provisioned on the App ID (paid / portal-enabled account), so
# automatic signing on an account without it fails to build the device app. When off, the tagged line is
# stripped from the generated spec (both iOS targets) so xcodegen omits it from the .entitlements files —
# an unmodified clone signs. No-op on-device: the value is already iOS's default protection level. Enable
# on a provisioned account with FABOLUS_DATA_PROTECTION=1 for release builds.
DATA_PROTECTION="${FABOLUS_DATA_PROTECTION:-0}"
# Time-Sensitive Notifications (CR-01/§6-B6) defaults OFF: com.apple.developer.usernotifications.time-sensitive
# needs the Time Sensitive Notifications capability provisioned on the App ID (paid / portal-enabled account),
# so automatic signing on an account without it fails to build the device app. When off, the tagged line is
# stripped from the generated spec so xcodegen omits it from faBolus.entitlements — an unmodified clone signs.
# No-op on the Simulator/CI build (the entitlement is inert). Enable on a provisioned account with
# FABOLUS_TIME_SENSITIVE=1 so the never-suppressible safety trio actually breaks through Focus/DND on device.
TIME_SENSITIVE="${FABOLUS_TIME_SENSITIVE:-0}"
# TandemKit backend pump-protocol stack. Default: consume by pinned revision (reproducible; §1.3
# version-pin, D-01). FABOLUS_TANDEM_LOCAL=1 swaps in the sibling path (../TandemKit) for day-to-day
# co-development (never for a build you keep — see project.yml comment on the TandemKit package).
TANDEM_LOCAL="${FABOLUS_TANDEM_LOCAL:-0}"
# Phase-0 (v0.5.0) per-CGM-source compile gates (TOPO-03/D-03). Nightscout is the only CGM source that
# still ships behind an APP_SOURCE_EXCLUDES file-exclude gate (see the app-source strip logic below).
# G6, LibreLinkUp, G7, and xDrip were Phase-1 flag-excluded, then Phase 2.5 retro-cleaned to a physical
# `git rm` from main (D-01/D-07, CLEAN-03) — their source files no longer exist here at all; they are
# preserved on origin/dev/cgm-extra. CGM_LIBRELINKUP is fully retired (no companion vendored package).
# The vendored DexcomG6Kit/G7SensorKit packages themselves are gone too, so there is no longer a
# CGM_G6/CGM_G7 gate at all — only Nightscout still has a compile gate below.
CGM_NIGHTSCOUT="${FABOLUS_CGM_NIGHTSCOUT:-1}"
# Phase 3 (03-02, REMOTE-02): the phone-peer PHONE_PEER compile gate is retired — the iPhone-to-iPhone
# peer remote is git rm'd from main outright (delete-on-main, D-01), preserved on dev/phone-remote, the
# same posture as the Phase 2.5 CGM retro-clean. The SHARED PhoneRemoteHost.swift Garmin/widget receiver
# core stays on main unconditionally (part of the always-included ios/faBolus tree).
# Phase 7 (07-01, FEAT-07): the FoodFinder compile gate (env override was named for this surface) is
# retired — the barcode/OpenFoodFacts + AI carb-estimate surface (Data/FoodFinder, Views/FoodFinder) is
# git rm'd from main outright (delete-on-main, D-01/D-03), preserved on dev/food-finder, the same
# posture as the Phase 2.5 CGM retro-clean / Phase 3 phone-peer retirement. No env-var declaration, no
# strip_block call, no exclude-list entry remains for it.
# BACKUP compile gate (BACKUP-01/D-02, Phase 6 06-02/D-08 owner carve-out). REMOVAL FLIP: `main`'s
# backup/restore, PrivacyData-export, and SiteAtlas surface is now permanently ABSENT — the 7
# app-layer files/dirs this flag used to gate are physically git rm'd from `main` (delete-on-main,
# preserved on dev/backup), and the default here flips to 0 so AppModel.swift's/App.swift's identical
# #if FABOLUS_BACKUP guards compile out with no dead engine retained by default. Per the owner's D-08
# carve-out, the on-device "Delete all on-device data" / "Full reset" erase path
# (AppModel.EraseOutcome/eraseAllOnDeviceHealthData/eraseEverythingFullReset) is NOT gated by this flag
# — it stays reachable + compiled regardless of BACKUP's value; PrivacyDataView.swift itself stays on
# `main` (trimmed to erase-only) for exactly that reason. The flag/gate machinery (this var, the
# project.yml BACKUP excludes block, the SWIFT_ACTIVE_COMPILATION_CONDITIONS token) is kept, not
# retired outright — `dev/backup`/`experimental` keep their own copies of these files with the files
# present and FABOLUS_BACKUP=1 default, unaffected by this main-only flip. Setting FABOLUS_BACKUP=1
# here is now an env-override-only escape hatch (no shipped effect: the excluded source no longer
# exists on `main` to bring back). CR-01 gap-closure fix: the compile-condition token
# (SWIFT_ACTIVE_COMPILATION_CONDITIONS' FABOLUS_BACKUP entry) is dropped unconditionally below,
# independent of this variable's value — see the `drop_flag FABOLUS_BACKUP` call further down for why
# (previously it only fired when BACKUP=0, so BACKUP=1 defined the flag while the gated types were
# already gone, breaking the build; that made the "no-op" claim below false until this fix).
BACKUP="${FABOLUS_BACKUP:-0}"
# Mobi capability-model placeholder (TOPO-03/D-03, RESEARCH Pattern 3 + Pitfall 5). Mobi support is NOT a
# strippable block — it is an `enum PumpModel` case + a `.mobiAdvanced` capability floor threaded through
# dose-adjacent faBolusCore / AccessPolicy / GatedPumpWrite. Phase 0 reserves ONLY the env-var plumbing here
# (default 1, a documented no-op TODAY); it adds ZERO `#if FABOLUS_MOBI` call sites — doing so would reach
# into the byte-identity-protected dose-adjacent code before Phase 9's careful capability-model surgery +
# oracle/parity re-run. The eventual home is the dev/mobi sub-branch (cut in 00-02); the real implementation
# is Phase 9. TandemKit needs no Mobi gate (it ships mobi-tagged messages unconditionally — RESEARCH §H).
MOBI="${FABOLUS_MOBI:-1}"

SPEC="project.generated.yml"
cp project.yml "$SPEC"

# Remove every line between "# >>> TAG" and "# <<< TAG" (inclusive). Handles multiple blocks per tag.
#
# The tag is matched to a word boundary. It used to be a bare substring match, which meant
# `strip_block FOO` also stripped every `# >>> FOO_BAR` block — so a tag that is a prefix of another
# silently removed the wrong lines. That bit for real on the (now-removed, delete-on-main, Phase 3
# 03-03) watch direct-to-pump gate: the "off" tag was a suffixed variant of the "on" tag, and the
# on-tag's strip_block call silently consumed the off-tag's block too, so the opt-out shipped the
# code it was meant to remove. Anchor, don't rely on tag names not colliding — see 03-RESEARCH.md.
strip_block() {
  awk -v tag="$1" '
    $0 ~ ("# >>> " tag "([^A-Za-z0-9_]|$)") { skip=1; next }
    $0 ~ ("# <<< " tag "([^A-Za-z0-9_]|$)") { skip=0; next }
    !skip { print }
  ' "$SPEC" > "$SPEC.tmp" && mv "$SPEC.tmp" "$SPEC"
}

# Remove one flag from the SWIFT_ACTIVE_COMPILATION_CONDITIONS lines only. Scoped to those lines (not
# a bare global sed) because the same flag names appear in prose comments — "unless
# FABOLUS_ICLOUD=1" would otherwise become "unless=1".
drop_flag() {
  sed -i '' "/SWIFT_ACTIVE_COMPILATION_CONDITIONS/ s/ $1//g" "$SPEC"
}

if [ "$GARMIN" = 0 ]; then
  strip_block GARMIN
  sed -i '' 's/ GARMIN//g' "$SPEC"        # drop the compile flag from SWIFT_ACTIVE_COMPILATION_CONDITIONS
fi
# Phase 3 (03-03, REMOTE-03/REMOTE-04): the watch-embed strip, the on-watch-eating strip, and the
# watch-direct-pump strip (+ its off-variant) are all retired — the whole Watch target they gated is
# deleted from project.yml outright (delete-on-main), so there is no compile-flag cascade left to
# collapse here. See dev/watch-remote / dev/watch-host REINTEGRATION.md to restore any of this.
if [ "$TANDEM_LOCAL" = 1 ]; then
  strip_block TANDEM_PINNED   # keep the sibling path: ../TandemKit — unpinned dev/co-dev build
  echo "  → TandemKit consumed by LOCAL PATH (FABOLUS_TANDEM_LOCAL=1) — unpinned dev build"
else
  strip_block TANDEM_LOCAL    # keep the pinned url:+revision: — the default, reproducible build
fi
if [ "$ICLOUD" = 0 ]; then
  strip_block ICLOUD                       # the ubiquity-kvstore entitlement → free-account build signs
  drop_flag FABOLUS_ICLOUD                 # drop the compile flag → the no-op iCloud stub compiles
fi
if [ "$TEMPRATE_CIQ_EXPERIMENTAL" = 0 ]; then
  drop_flag FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL   # drop the compile flag → the CIQ-off precondition stays enforced
fi
if [ "$DATA_PROTECTION" = 0 ]; then
  # The default-data-protection entitlement is declared in project.yml under entitlements.properties for
  # BOTH iOS targets (faBolus + faBolusWidgets); xcodegen writes it into the generated .entitlements
  # files. Strip both tagged lines from the spec BEFORE xcodegen runs so it never emits the entitlement —
  # an account without the Data Protection capability can then sign the device app. (strip_block handles
  # the two blocks in one call.)
  strip_block DATA_PROTECTION
fi

if [ "$TIME_SENSITIVE" = 0 ]; then
  # The time-sensitive entitlement is declared in project.yml under the faBolus target's
  # entitlements.properties. Strip the tagged line BEFORE xcodegen runs so it never emits the entitlement —
  # an account without the Time Sensitive Notifications capability can then sign the device app. NotificationPoster
  # still sets .timeSensitive in code (iOS silently downgrades it to .active when the capability is absent).
  strip_block TIME_SENSITIVE
fi

# Phase-0 per-surface app-source compile gates (TOPO-03/D-03). Only Nightscout still gates a source
# FILE via this APP_SOURCE_EXCLUDES excludes: list — G6/LibreLinkUp/G7/xDrip's file-exclude entries were
# retired in Phase 2.5 (their source files are git rm'd outright, D-01/D-07); PHONE_PEER's were retired
# in Phase 3 (03-02, same posture — the peer files are git rm'd outright, not excluded); FoodFinder's
# gate was retired in Phase 7 (07-01, same posture — the FoodFinder dirs are git rm'd outright, not
# excluded).
# When EVERY remaining gate is at its default (=1, surface PRESENT) the entire excludes: block is
# removed; otherwise the block is kept and only the still-present (=1) surfaces' exclude lines are
# dropped, leaving the =0 surface(s) excluded.
if [ "$CGM_NIGHTSCOUT" = 1 ] && [ "$BACKUP" = 1 ]; then
  strip_block APP_SOURCE_EXCLUDES   # all remaining app-source surfaces present → drop the whole excludes: block
else
  [ "$CGM_NIGHTSCOUT" = 1 ]  && strip_block CGM_NIGHTSCOUT
  [ "$BACKUP" = 1 ]          && strip_block BACKUP            # present → drop the Backup/SiteAtlas exclude lines
fi
# The compile-condition token (not just the file excludes above) is ALWAYS dropped on main, regardless
# of $BACKUP's value — AppModel.swift's/App.swift's #if FABOLUS_BACKUP guards must compile out
# unconditionally here, because the 7 files those guards reference (SiteAtlasStore, PrivacyDataExport,
# ICloudSettingsSync, ...) are physically git rm'd from main (06-02); there is nothing left for the flag
# to gate even if a developer sets FABOLUS_BACKUP=1 (CR-01 gap-closure fix — see 06-REVIEW.md). Leaving
# this conditional on `$BACKUP = 0` (the pre-fix code) let FABOLUS_BACKUP=1 define the flag while the
# gated types were gone, which broke the build; unconditional drop_flag makes the override a genuine
# no-op instead of a misleading one. The erase/full-reset MARK section in AppModel.swift is deliberately
# NOT wrapped in this flag (D-08) so it is unaffected either way.
drop_flag FABOLUS_BACKUP

echo "generate-project: Garmin=$GARMIN iCloud=$ICLOUD DataProtection=$DATA_PROTECTION TimeSensitive=$TIME_SENSITIVE TandemLocal=$TANDEM_LOCAL TempRateCiqExperimental=$TEMPRATE_CIQ_EXPERIMENTAL"
echo "generate-project (Phase-0 app-source gates): CgmNightscout=$CGM_NIGHTSCOUT Backup=$BACKUP (G6/LibreLinkUp/G7/xDrip sources git rm'd from main outright — Phase 2.5 retro-clean, D-07; phone-peer git rm'd from main outright — Phase 3, 03-02; FoodFinder git rm'd from main outright — Phase 7, 07-01; backup/restore+PrivacyData-export+SiteAtlas sources git rm'd from main outright — Phase 6, 06-02; the vendored DexcomG6Kit/G7SensorKit packages are gone outright; Nightscout still default-present)"
[ "$CGM_NIGHTSCOUT" = 0 ] && echo "  → building WITHOUT the Nightscout CGM source + backfill (FABOLUS_CGM_NIGHTSCOUT=0)"
[ "$BACKUP" = 0 ] && echo "  → building WITHOUT backup/restore + PrivacyData export + SiteAtlas (FABOLUS_BACKUP=0, default on main) — 7 source files/dirs are physically absent (git rm'd, Phase 6 06-02); the on-device erase/full-reset path (Delete all on-device data / Full reset) STAYS present (D-08 owner carve-out)"
[ "$BACKUP" = 1 ] && echo "  → FABOLUS_BACKUP=1 env-override requested on main — a genuine no-op: the 7 backup/restore/SiteAtlas source files no longer exist here to include (git rm'd, Phase 6 06-02; see dev/backup), AND the FABOLUS_BACKUP compile-condition token is unconditionally dropped below regardless of this override, so the #if FABOLUS_BACKUP guards in AppModel.swift/App.swift stay compiled OUT (CR-01 gap-closure fix)"
echo "  → FABOLUS_MOBI=$MOBI (placeholder plumbing — documented NO-OP this milestone; zero #if FABOLUS_MOBI call sites; Mobi capability-model surgery is Phase 9's job, dev/mobi sub-branch)"
[ "$GARMIN" = 0 ] && echo "  → building WITHOUT the Garmin Connect IQ SDK (not found at $SDK_DIR)"
[ "$ICLOUD" = 0 ] && echo "  → building WITHOUT automatic iCloud settings sync (needs a paid account; set FABOLUS_ICLOUD=1 to enable) — file backup/restore still works"
[ "$ICLOUD" = 1 ] && echo "  → automatic iCloud settings sync ON (FABOLUS_ICLOUD=1) — requires the iCloud capability on a paid account; falls back to local-only when signed out"
[ "$DATA_PROTECTION" = 0 ] && echo "  → building WITHOUT the §13 Data Protection entitlement (needs the capability provisioned on the App ID; set FABOLUS_DATA_PROTECTION=1 to enable) — on-device protection unchanged (iOS default level)"
[ "$DATA_PROTECTION" = 1 ] && echo "  → §13 Data Protection entitlement ON (FABOLUS_DATA_PROTECTION=1) — requires the Data Protection capability on App IDs com.fabolus.app + .widgets"
[ "$TIME_SENSITIVE" = 0 ] && echo "  → building WITHOUT the Time-Sensitive Notifications entitlement (needs the capability provisioned on the App ID; set FABOLUS_TIME_SENSITIVE=1 to enable) — .timeSensitive is set in code but iOS downgrades it to .active until the capability is provisioned"
[ "$TIME_SENSITIVE" = 1 ] && echo "  → Time-Sensitive Notifications entitlement ON (FABOLUS_TIME_SENSITIVE=1) — the safety trio breaks through Focus/DND via .timeSensitive; requires the capability on App ID com.fabolus.app"
[ "$TEMPRATE_CIQ_EXPERIMENTAL" = 0 ] && echo "  → building WITHOUT the D-02 experimental Control-IQ+ temp-rate overturn (default — CIQ-off is still required to set a temp rate)"
[ "$TEMPRATE_CIQ_EXPERIMENTAL" = 1 ] && echo "  → ⚠️  D-02 EXPERIMENTAL Control-IQ+ temp-rate overturn ON (FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL=1) — a temp rate can now be set while Control-IQ+ is on, UNVERIFIED until the Phase-11 saline bench. Local/bench builds only."

# Written before xcodegen runs: XcodeGen resolves the app target's source list (the recursive `- path:
# ios/faBolus`) at generation time, so the generated AppRevision.swift must already exist on disk or it
# is never picked up. Every build path (build-sim.sh, test-ios.sh, CI) already runs this script, so this
# single hook reaches all of them.
./scripts/stamp-revision.sh >/dev/null

xcodegen generate --spec "$SPEC"

# §1.3 version-pin (D-04): restore the tracked, root-level canonical Package.resolved into the
# generated project's swiftpm dir so a fresh generation reuses the pinned graph (TandemKit)
# instead of re-resolving latest for every transitive dependency.
if [ -f "$REPO/Package.resolved" ]; then
  SWIFTPM_DIR="$REPO/faBolus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$SWIFTPM_DIR"
  cp "$REPO/Package.resolved" "$SWIFTPM_DIR/Package.resolved"
fi
