#!/usr/bin/env bash
# check-dose-byte-identity.sh — reusable cross-branch dose/signed byte-identity check (INV-01 / INV-03).
#
# The narrow-main invariant every removal phase inherits: a surface is removed via a RUNTIME gate
# (settings-forced-value + UI-hide) or a COMPILE gate on its OWN target/sources — NEVER by editing the
# dose/signed core. So the signed-command / dose-math sources MUST stay byte-identical between `main`
# and every per-surface `dev/<surface>` sub-branch. This check diffs exactly those sources and exits
# NON-ZERO with a named diffstat on any drift.
#
# The guarded dose/signed sources (faBolus repo):
#   - Packages/faBolusCore                     (BolusMath, oracle-parity, GatedPumpWrite, AccessPolicy,
#                                               StackingGuard, RemoteCommand — the signed/dose core)
#   - ios/faBolus/Data/AppModel.swift          (the app-side dose/delivery paths)
#   - ios/faBolus/Data/TandemBackend.swift     (the signed pump-write backend)
#
# On `main` at Phase-0 completion the diff is empty for every `dev/<surface>` sub-branch: the sub-branches
# are code-identical to the baseline (no surface has been removed yet — that starts at Phase 1).
#
# This is NOT a tautology: `git diff --quiet` returns 1 on ANY byte difference. Proof/injected-diff demo:
#   git diff --quiet pre-narrow/2026-08-18 main -- Packages/faBolusCore   # exits 1 (130-commit-stale ref)
#
# Read-only. Every later removal phase runs this UNCHANGED as part of the exit gate.
#
# Usage:
#   scripts/check-dose-byte-identity.sh                 # diff main vs every dev/<surface> sub-branch
#   scripts/check-dose-byte-identity.sh dev/mac         # diff main vs a single branch
#   BASE_REF=pre-narrow/2026-08-20 scripts/check-dose-byte-identity.sh   # override the base ref
set -uo pipefail

cd "$(dirname "$0")/.."

BASE_REF="${BASE_REF:-main}"

# The dose/signed source set. Add here (once) and every phase inherits the wider guard.
DOSE_PATHS=(
  "Packages/faBolusCore"
  "ios/faBolus/Data/AppModel.swift"
  "ios/faBolus/Data/TandemBackend.swift"
)

# Branch list: explicit arg, else every local dev/<surface> sub-branch.
# (portable to bash 3.2 — no `mapfile`/`readarray`)
BRANCHES=()
if [ "$#" -ge 1 ]; then
  BRANCHES=("$@")
else
  while IFS= read -r ref; do
    [ -n "$ref" ] && BRANCHES+=("$ref")
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/dev 2>/dev/null)
fi

if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "⚠ no dev/<surface> sub-branches found (nothing to compare) — pass a branch name explicitly"
  exit 0
fi

fail=0
printf '== check-dose-byte-identity.sh — base: %s — %d branch(es) ==\n' "$BASE_REF" "${#BRANCHES[@]}"

for br in "${BRANCHES[@]}"; do
  if ! git rev-parse --verify --quiet "$br" >/dev/null; then
    printf '  ✗ %-20s ref does not exist\n' "$br"
    fail=1
    continue
  fi
  if git diff --quiet "$BASE_REF" "$br" -- "${DOSE_PATHS[@]}"; then
    printf '  ✓ %-20s dose/signed core byte-identical to %s\n' "$br" "$BASE_REF"
  else
    printf '  ✗ %-20s DOSE/SIGNED DRIFT vs %s:\n' "$br" "$BASE_REF"
    git diff --stat "$BASE_REF" "$br" -- "${DOSE_PATHS[@]}" | sed 's/^/        /'
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "❌ dose/signed byte-identity VIOLATED — a removal must never touch the dose/signed core"
  exit 1
fi
echo "✅ dose/signed core byte-identical across all compared branches"
