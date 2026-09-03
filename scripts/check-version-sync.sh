#!/usr/bin/env bash
# Asserts the generated build stamp never becomes git-tracked, then delegates freshness to
# scripts/stamp-revision.sh --check.
#
# scripts/stamp-revision.sh has exactly one way to go quietly wrong: a stale generated stamp left on
# disk describing a tree that no longer exists, compiled straight into a build without anyone
# noticing. This script is the guard for that, in two parts:
#   1. The stamp must never creep into COMMITTED source. It cannot be safe there: a commit's hash is a
#      function of its own contents, so a committed hash could only ever be an earlier commit's —
#      permanently stale. ios/faBolus/Generated/.gitignore already blocks an accidental `git add`, but
#      an explicit `-f` would bypass it, so it is asserted here rather than assumed.
#   2. Freshness itself is delegated to `stamp-revision.sh --check`, which reuses the generator's own
#      derivation rather than a second copy of it, so the guard cannot drift from the thing it guards.
#
# Exit codes: 0 = in sync (or skipped, when nothing has been built yet)   1 = drift   2 = bad invocation
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP="ios/faBolus/Generated/AppRevision.swift"

if [ ! -f scripts/stamp-revision.sh ]; then
  echo "scripts/stamp-revision.sh not found — this script must run from the faBolus repo."
  exit 2
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
  if git ls-files --error-unmatch "$STAMP" >/dev/null 2>&1; then
    echo "DRIFT: $STAMP is TRACKED by git — it must be generated per build, never committed."
    echo "  A committed stamp freezes at one commit's hash and then misidentifies every later build."
    echo "  Fix: git rm --cached $STAMP"
    exit 1
  fi
fi

./scripts/stamp-revision.sh --check
