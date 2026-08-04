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
#     and the three PumpX2Kit dependencies are dropped, so the watch app links no pump BLE stack at
#     all. Enable for bench work only with FABOLUS_WATCH_DIRECT_PUMP=1.
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
# faBolusNudge advisory SDK (Smart Assist: bolus guardrail, predictive-low, insights, autotune, eating
# detection). Auto-detected: if the (private) repo isn't reachable, the package + its 7 products + the
# FABOLUS_NUDGE compile flag are stripped and the Smart Assist features compile out — the app still
# builds. Override with FABOLUS_NUDGE=0/1.
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
  strip_block WATCH_DIRECT_PUMP   # the PumpX2Kit deps — the watch then links no pump BLE stack
  drop_flag FABOLUS_WATCH_DIRECT_PUMP
else
  strip_block WATCH_DIRECT_PUMP_OFF   # the `excludes: [direct-pump]` — compile the directory in
fi
if [ "$NUDGE" = 0 ]; then
  strip_block NUDGE                        # the faBolusNudge package + its 7 product dependencies
  sed -i '' 's/ FABOLUS_NUDGE//g' "$SPEC"  # drop the compile flag → Smart Assist code compiles out
fi

echo "generate-project: Garmin=$GARMIN Watch=$WATCH OnWatchEating=$ONWATCH Nudge=$NUDGE WatchDirectPump=$DIRECT_PUMP"
[ "$NUDGE" = 0 ] && echo "  → building WITHOUT the faBolusNudge SDK (repo unavailable) — Smart Assist features excluded"
[ "$GARMIN" = 0 ] && echo "  → building WITHOUT the Garmin Connect IQ SDK (not found at $SDK_DIR)"
[ "$WATCH" = 0 ]  && echo "  → building WITHOUT the Apple Watch app (FABOLUS_WATCH=0)"
[ "$ONWATCH" = 0 ] && echo "  → building WITHOUT on-watch eating detection (needs paid HealthKit; set FABOLUS_ONWATCH_EATING=1 to enable)"
[ "$ONWATCH" = 1 ] && echo "  → on-watch eating detection ON (FABOLUS_ONWATCH_EATING=1) — requires HealthKit on a paid account"
[ "$DIRECT_PUMP" = 0 ] && echo "  → building WITHOUT the watch direct-to-pump path (C9) — the watch links no pump BLE stack"
[ "$DIRECT_PUMP" = 1 ] && echo "  → ⚠️  watch DIRECT-TO-PUMP path ON (FABOLUS_WATCH_DIRECT_PUMP=1) — violates C9, evicts the phone's pairing, BENCH ONLY. Do not wear this build."

xcodegen generate --spec "$SPEC"
