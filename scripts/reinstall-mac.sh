#!/usr/bin/env bash
#
# One-shot: pull the newest main, build the macOS remote app, and (re)install it to /Applications.
# A convenience for running the faBolus Mac remote from source between releases.
#
# Prereqs: xcodegen on PATH, and a signing setup (LocalConfig.xcconfig with your APP_BUNDLE_ID +
# DEVELOPMENT_TEAM). The Mac app has no Garmin/Watch dependencies, so neither is needed here.
#
# Usage:  scripts/reinstall-mac.sh            # update to origin/main, build, install, relaunch
#         SKIP_PULL=1 scripts/reinstall-mac.sh # build the current working tree as-is
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

APP="faBolusMac"
DD="${DERIVED_DATA:-/tmp/fb_mac_dd}"
DEST="/Applications/${APP}.app"
LOG="/tmp/reinstall-mac.log"

if [ "${SKIP_PULL:-0}" != 1 ]; then
  echo "==> Updating to newest origin/main…"
  git fetch origin --quiet
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "   ! Uncommitted tracked changes — skipping fast-forward; building the current tree."
  elif ! git merge --ff-only origin/main >/dev/null 2>&1; then
    echo "   ! Could not fast-forward (diverged?) — building the current tree."
  fi
fi
echo "   at $(git rev-parse --short HEAD) — $(git log -1 --format='%s')"

echo "==> Generating Xcode project…"
if [ -x scripts/generate-project.sh ]; then scripts/generate-project.sh >/dev/null
else xcodegen generate >/dev/null; fi

echo "==> Building ${APP} (Debug)…"
if ! xcodebuild -project faBolus.xcodeproj -scheme "$APP" -destination 'platform=macOS' \
     -configuration Debug -derivedDataPath "$DD" -allowProvisioningUpdates build >"$LOG" 2>&1; then
  echo "   BUILD FAILED — last lines of $LOG:"; grep -E "error:|BUILD FAILED" "$LOG" | tail -8; exit 1
fi

SRC="$DD/Build/Products/Debug/${APP}.app"
echo "==> Installing to ${DEST}…"
pkill -f "${DEST}/Contents/MacOS/${APP}" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --strict "$DEST" >/dev/null 2>&1 && echo "   signature OK"
open "$DEST"
echo "==> Done — ${APP} reinstalled from $(git rev-parse --short HEAD) and relaunched (menu-bar item, top-right)."
