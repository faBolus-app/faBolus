#!/usr/bin/env bash
#
# Generate faBolus.xcodeproj, making Garmin (Connect IQ SDK) and the Apple Watch app OPTIONAL so the
# app compiles/installs for users who don't have them.
#
#   - Garmin: auto-detected. If the Connect IQ SDK vendor folder is absent, the ConnectIQ package +
#     dependency are removed from the spec and the GARMIN compile flag is dropped, so nothing links or
#     imports the SDK. Override with FABOLUS_GARMIN=0/1.
#   - Apple Watch: on by default. Set FABOLUS_WATCH=0 to build the phone app without embedding the
#     watch app (drops the embed dependency + the WATCH_EMBEDDED flag).
#   - On-watch eating detection (Phase 5, step 6): OFF by default because it needs the **paid**
#     HealthKit entitlement (an HKWorkoutSession keeps CoreMotion alive). When off, every paid-only
#     piece (the HealthKit entitlement, WKBackgroundModes/NSMotion keys, the EatingDetectionKit deps,
#     the bundled model, and the FABOLUS_ONWATCH_EATING compile flag) is stripped, so the app builds
#     and installs on a **free** Apple account. Turn it on with FABOLUS_ONWATCH_EATING=1 once you've
#     enabled HealthKit on a paid account. The Garmin eating path (phone-side inference) needs none of
#     this and works regardless.
#   - Watch direct-to-pump (watch/faBolusWatch/direct-pump/): OFF by default and must stay off in any
#     build a person wears. It is a second pump-connection holder that bypasses the PumpBackend seam
#     (constraint C9) and pairing it EVICTS the phone's pairing. When off, the directory is excluded
#     and the three TandemKit dependencies are dropped, so the watch app links no pump BLE stack at
#     all. Enable for bench work only with FABOLUS_WATCH_DIRECT_PUMP=1.
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
# included at build time. Re-run with the SDK present / FABOLUS_WATCH=1 to restore it.
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
WATCH="${FABOLUS_WATCH:-1}"

# faBolusNudge advisory SDK (Smart Assist: on-device eating detection + meal-detection intelligence).
# Auto-detected: if the (private) repo isn't reachable, the package + its 6 products + the
# FABOLUS_NUDGE compile flag are stripped and those Smart Assist features compile out — the app still
# builds (retrospective insights live in faBolusCore and are unaffected). Override with FABOLUS_NUDGE=0/1.
if [ -n "${FABOLUS_NUDGE:-}" ]; then
  NUDGE="$FABOLUS_NUDGE"
else
  NUDGE=1
  git ls-remote https://github.com/faBolus-app/faBolusNudge.git HEAD >/dev/null 2>&1 || NUDGE=0
fi
# On-watch eating detection defaults OFF (paid HealthKit entitlement required). Auto-excluded unless
# the user opts in on a paid account. Also force-off if the watch app itself is excluded, or if the
# nudge SDK (which provides the eating model kit) is unavailable.
ONWATCH="${FABOLUS_ONWATCH_EATING:-0}"
[ "$WATCH" = 0 ] && ONWATCH=0
[ "$NUDGE" = 0 ] && ONWATCH=0
# The watch's direct-to-pump path (watch/faBolusWatch/direct-pump/) defaults OFF and must stay off in
# any build a person wears. It is a SECOND pump-connection holder that bypasses the PumpBackend seam,
# so constraint C9 ("one owner, N remotes") is false in any build that includes it — and pairing it
# EVICTS the phone's pairing, which on a Mobi means the charging base is needed to recover. Same
# posture as faBolusGarmin's direct-pump/. Bench use only; see watch/faBolusWatch/direct-pump/STATUS.md.
DIRECT_PUMP="${FABOLUS_WATCH_DIRECT_PUMP:-0}"
[ "$WATCH" = 0 ] && DIRECT_PUMP=0
# Automatic iCloud settings sync (NSUbiquitousKeyValueStore) defaults OFF: it needs a paid Apple
# Developer account + the iCloud capability, which would break the free-account build. When off, the
# entitlement block and the FABOLUS_ICLOUD compile flag are stripped so the no-op stub compiles and an
# unmodified clone signs on a free account. Enable on a paid account with FABOLUS_ICLOUD=1.
ICLOUD="${FABOLUS_ICLOUD:-0}"
# Apple Health (HealthKit) import/export (Phase 09.23, D-10/D-13): the WHOLE HealthKit surface — the
# existing HealthKit CGM source + on-demand HR reader, PLUS the new retrospective carbs/insulin
# import and the new bolus export — needs the paid Apple Developer Program to provision the
# `com.apple.developer.healthkit` capability, so it defaults OFF and an unmodified clone (and CI)
# signs on a free account. When off, the tagged entitlement + NSHealthUpdateUsageDescription block(s)
# and the FABOLUS_HEALTHKIT compile flag are stripped, so the whole HealthKit surface compiles out.
# Enable on a paid account with FABOLUS_HEALTHKIT=1.
HEALTHKIT="${FABOLUS_HEALTHKIT:-0}"
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
# CGM_G6/CGM_G7 remain ONLY to drive the CGM_G6_KIT/CGM_G7_KIT project.yml PACKAGE-block strip (D-02) —
# they no longer gate any source FILE (the files they used to gate are gone unconditionally now).
CGM_G6="${FABOLUS_CGM_G6:-0}"
CGM_NIGHTSCOUT="${FABOLUS_CGM_NIGHTSCOUT:-1}"
CGM_G7="${FABOLUS_CGM_G7:-0}"
# Phase 3 (03-02, REMOTE-02): the phone-peer PHONE_PEER compile gate is retired — the iPhone-to-iPhone
# peer remote is git rm'd from main outright (delete-on-main, D-01), preserved on dev/phone-remote, the
# same posture as the Phase 2.5 CGM retro-clean. The SHARED PhoneRemoteHost.swift Garmin/widget receiver
# core stays on main unconditionally (part of the always-included ios/faBolus tree).
# FoodFinder compile gate (TOPO-03/D-03, RESEARCH Pattern 2). Default 1 = the barcode/food-carb surface is
# PRESENT. At 0, exactly the three FoodFinder source dirs (Data/FoodFinder, Views/FoodFinder,
# Vendor/LoopPowerPack/FoodFinder) are excluded via the APP_SOURCE_EXCLUDES list — a nested-directory excludes:
# shape validated with a real xcodegen generate at both default and =0. The removal flip is Phase 7's job.
FOODFINDER="${FABOLUS_FOODFINDER:-1}"
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
# silently removed the wrong lines. That bit for real: WATCH_DIRECT_PUMP consumed
# WATCH_DIRECT_PUMP_OFF, which is the block whose whole job is to EXCLUDE the direct-pump path, so
# the opt-out shipped the code it was meant to remove. Anchor, don't rely on tag names not colliding.
strip_block() {
  awk -v tag="$1" '
    $0 ~ ("# >>> " tag "([^A-Za-z0-9_]|$)") { skip=1; next }
    $0 ~ ("# <<< " tag "([^A-Za-z0-9_]|$)") { skip=0; next }
    !skip { print }
  ' "$SPEC" > "$SPEC.tmp" && mv "$SPEC.tmp" "$SPEC"
}

# Remove one flag from the SWIFT_ACTIVE_COMPILATION_CONDITIONS lines only. Scoped to those lines (not
# a bare global sed) because the same flag names appear in prose comments — "unless
# FABOLUS_ONWATCH_EATING=1" would otherwise become "unless=1".
drop_flag() {
  sed -i '' "/SWIFT_ACTIVE_COMPILATION_CONDITIONS/ s/ $1//g" "$SPEC"
}

if [ "$GARMIN" = 0 ]; then
  strip_block GARMIN
  sed -i '' 's/ GARMIN//g' "$SPEC"        # drop the compile flag from SWIFT_ACTIVE_COMPILATION_CONDITIONS
fi
if [ "$WATCH" = 0 ]; then
  strip_block WATCH
  sed -i '' 's/ WATCH_EMBEDDED//g' "$SPEC"
fi
if [ "$ONWATCH" = 0 ]; then
  # Strip every paid-account-only piece so the app builds/installs on a free account.
  strip_block ONWATCH_EATING
  drop_flag FABOLUS_ONWATCH_EATING
fi
if [ "$DIRECT_PUMP" = 0 ]; then
  strip_block WATCH_DIRECT_PUMP   # the TandemKit deps — the watch then links no pump BLE stack
  drop_flag FABOLUS_WATCH_DIRECT_PUMP
else
  strip_block WATCH_DIRECT_PUMP_OFF   # the `excludes: [direct-pump]` — compile the directory in
fi
if [ "$NUDGE" = 0 ]; then
  strip_block NUDGE                        # the faBolusNudge package + its 6 product dependencies
  sed -i '' 's/ FABOLUS_NUDGE//g' "$SPEC"  # drop the compile flag → Smart Assist code compiles out
fi
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
if [ "$HEALTHKIT" = 0 ]; then
  strip_block HEALTHKIT                    # com.apple.developer.healthkit(+.access) + usage string → free-account signs
  drop_flag FABOLUS_HEALTHKIT              # drop the compile flag → the whole HealthKit surface compiles out
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

# Phase-0 per-surface app-source compile gates (TOPO-03/D-03). Only Nightscout/FOODFINDER still gate a
# source FILE via this APP_SOURCE_EXCLUDES excludes: list — G6/LibreLinkUp/G7/xDrip's file-exclude
# entries were retired in Phase 2.5 (their source files are git rm'd outright, D-01/D-07); PHONE_PEER's
# were retired in Phase 3 (03-02, same posture — the peer files are git rm'd outright, not excluded).
# When EVERY remaining gate is at its default (=1, surface PRESENT) the entire excludes: block is
# removed; otherwise the block is kept and only the still-present (=1) surfaces' exclude lines are
# dropped, leaving the =0 surface(s) excluded.
if [ "$CGM_NIGHTSCOUT" = 1 ] && [ "$FOODFINDER" = 1 ]; then
  strip_block APP_SOURCE_EXCLUDES   # all remaining app-source surfaces present → drop the whole excludes: block
else
  [ "$CGM_NIGHTSCOUT" = 1 ]  && strip_block CGM_NIGHTSCOUT
  [ "$FOODFINDER" = 1 ]      && strip_block FOODFINDER        # present → drop the FoodFinder-dir exclude lines
fi
# FABOLUS_CGM_G6=0 (default) drops the DexcomG6Kit SPM package + the app-target dependency on it — the
# ONLY thing CGM_G6 still gates after Phase 2.5 (its source-file exclude entry no longer exists; the
# source itself is git rm'd, D-01/D-07). Distinct tag from CGM_G6 (word-boundary anchored in
# strip_block, so CGM_G6 never matches CGM_G6_KIT and vice-versa — Pitfall 2).
if [ "$CGM_G6" = 0 ]; then
  strip_block CGM_G6_KIT
fi

# FABOLUS_CGM_G7=0 (default) drops the G7SensorKit SPM package + the app-target/watch-target
# dependency on it — the ONLY thing CGM_G7 still gates after Phase 2.5 (its standalone Shared/
# source-file exclude entries no longer exist on either target; the source itself is git rm'd,
# D-01/D-07). Mirrors the CGM_G6/CGM_G6_KIT fence shape exactly.
if [ "$CGM_G7" = 0 ]; then
  strip_block CGM_G7_KIT
fi

echo "generate-project: Garmin=$GARMIN Watch=$WATCH OnWatchEating=$ONWATCH Nudge=$NUDGE WatchDirectPump=$DIRECT_PUMP iCloud=$ICLOUD HealthKit=$HEALTHKIT DataProtection=$DATA_PROTECTION TimeSensitive=$TIME_SENSITIVE TandemLocal=$TANDEM_LOCAL TempRateCiqExperimental=$TEMPRATE_CIQ_EXPERIMENTAL"
echo "generate-project (Phase-0 app-source gates): CgmG6Kit=$CGM_G6 CgmNightscout=$CGM_NIGHTSCOUT CgmG7Kit=$CGM_G7 FoodFinder=$FOODFINDER (G6/LibreLinkUp/G7/xDrip sources git rm'd from main outright — Phase 2.5 retro-clean, D-07; phone-peer git rm'd from main outright — Phase 3, 03-02; CGM_G6/CGM_G7 now only gate their vendored SPM package; Nightscout/FoodFinder still default-present)"
[ "$CGM_G6" = 0 ] && echo "  → building WITHOUT the DexcomG6Kit package/dependency (FABOLUS_CGM_G6=0, default) — the Dexcom G5/G6/ONE BLE decoder is unlinked; the app-side source was git rm'd from main in Phase 2.5 (D-07), preserved on dev/cgm-extra; G7SensorKit/ShareClient kept"
[ "$CGM_NIGHTSCOUT" = 0 ] && echo "  → building WITHOUT the Nightscout CGM source + backfill (FABOLUS_CGM_NIGHTSCOUT=0)"
[ "$CGM_G7" = 0 ] && echo "  → building WITHOUT the G7SensorKit package/dependency on iOS AND watch (FABOLUS_CGM_G7=0, default) — the Dexcom G7/ONE+ BLE decoder is unlinked; the app-side source was git rm'd from main in Phase 2.5 (D-07), preserved on dev/cgm-extra"
[ "$FOODFINDER" = 0 ] && echo "  → building WITHOUT FoodFinder (FABOLUS_FOODFINDER=0) — the 3 FoodFinder source dirs excluded"
echo "  → FABOLUS_MOBI=$MOBI (placeholder plumbing — documented NO-OP this milestone; zero #if FABOLUS_MOBI call sites; Mobi capability-model surgery is Phase 9's job, dev/mobi sub-branch)"
[ "$NUDGE" = 0 ] && echo "  → building WITHOUT the faBolusNudge SDK (repo unavailable) — Smart Assist features excluded"
[ "$GARMIN" = 0 ] && echo "  → building WITHOUT the Garmin Connect IQ SDK (not found at $SDK_DIR)"
[ "$WATCH" = 0 ]  && echo "  → building WITHOUT the Apple Watch app (FABOLUS_WATCH=0)"
[ "$ONWATCH" = 0 ] && echo "  → building WITHOUT on-watch eating detection (needs paid HealthKit; set FABOLUS_ONWATCH_EATING=1 to enable)"
[ "$ONWATCH" = 1 ] && echo "  → on-watch eating detection ON (FABOLUS_ONWATCH_EATING=1) — requires HealthKit on a paid account"
[ "$DIRECT_PUMP" = 0 ] && echo "  → building WITHOUT the watch direct-to-pump path (C9) — the watch links no pump BLE stack"
[ "$DIRECT_PUMP" = 1 ] && echo "  → ⚠️  watch DIRECT-TO-PUMP path ON (FABOLUS_WATCH_DIRECT_PUMP=1) — violates C9, evicts the phone's pairing, BENCH ONLY. Do not wear this build."
[ "$ICLOUD" = 0 ] && echo "  → building WITHOUT automatic iCloud settings sync (needs a paid account; set FABOLUS_ICLOUD=1 to enable) — file backup/restore still works"
[ "$ICLOUD" = 1 ] && echo "  → automatic iCloud settings sync ON (FABOLUS_ICLOUD=1) — requires the iCloud capability on a paid account; falls back to local-only when signed out"
[ "$HEALTHKIT" = 0 ] && echo "  → building WITHOUT Apple Health (HealthKit) — the CGM source, HR reader, carbs/insulin import, and bolus export all compile out (needs a paid account; set FABOLUS_HEALTHKIT=1 to enable)"
[ "$HEALTHKIT" = 1 ] && echo "  → Apple Health (HealthKit) ON (FABOLUS_HEALTHKIT=1) — requires the HealthKit capability on a paid account"
[ "$DATA_PROTECTION" = 0 ] && echo "  → building WITHOUT the §13 Data Protection entitlement (needs the capability provisioned on the App ID; set FABOLUS_DATA_PROTECTION=1 to enable) — on-device protection unchanged (iOS default level)"
[ "$DATA_PROTECTION" = 1 ] && echo "  → §13 Data Protection entitlement ON (FABOLUS_DATA_PROTECTION=1) — requires the Data Protection capability on App IDs com.fabolus.app + .widgets"
[ "$TIME_SENSITIVE" = 0 ] && echo "  → building WITHOUT the Time-Sensitive Notifications entitlement (needs the capability provisioned on the App ID; set FABOLUS_TIME_SENSITIVE=1 to enable) — .timeSensitive is set in code but iOS downgrades it to .active until the capability is provisioned"
[ "$TIME_SENSITIVE" = 1 ] && echo "  → Time-Sensitive Notifications entitlement ON (FABOLUS_TIME_SENSITIVE=1) — the safety trio breaks through Focus/DND via .timeSensitive; requires the capability on App ID com.fabolus.app"
[ "$TEMPRATE_CIQ_EXPERIMENTAL" = 0 ] && echo "  → building WITHOUT the D-02 experimental Control-IQ+ temp-rate overturn (default — CIQ-off is still required to set a temp rate)"
[ "$TEMPRATE_CIQ_EXPERIMENTAL" = 1 ] && echo "  → ⚠️  D-02 EXPERIMENTAL Control-IQ+ temp-rate overturn ON (FABOLUS_TEMPRATE_CIQ_EXPERIMENTAL=1) — a temp rate can now be set while Control-IQ+ is on, UNVERIFIED until the Phase-11 saline bench. Local/bench builds only."

xcodegen generate --spec "$SPEC"

# §1.3 version-pin (D-04): restore the tracked, root-level canonical Package.resolved into the
# generated project's swiftpm dir so a fresh generation reuses the pinned graph (TandemKit +
# faBolusNudge/LoopAlgorithm) instead of re-resolving latest for every transitive dependency.
if [ -f "$REPO/Package.resolved" ]; then
  SWIFTPM_DIR="$REPO/faBolus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$SWIFTPM_DIR"
  cp "$REPO/Package.resolved" "$SWIFTPM_DIR/Package.resolved"
fi
