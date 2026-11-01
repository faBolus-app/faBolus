#!/usr/bin/env bash
# verify-pre-narrow-tags.sh — reusable full-surface-baseline currency check (TOPO-01 / INV-01).
#
# Asserts, for each of the 3 lockstep repos (faBolus, TandemKit, faBolusGarmin), that the operative
# pre-narrow baseline tag is:
#   (1) ANNOTATED         — `git cat-file -t <tag>` == "tag" (a lightweight/commit tag is a finding:
#                            the 08-18 tags were lightweight AND 130 commits stale — see 00-RESEARCH.md).
#   (2) AN ANCESTOR of main — the baseline is recoverable / has not been orphaned or force-moved.
#   (3) NOT BEHIND main    — `git rev-list --count main..<tag>` == 0, i.e. `main` contains every commit
#                            the tag has (main is a linear descendant, the baseline has NOT diverged).
#
# NOTE on the currency predicate (deviation from 00-04-PLAN.md's literal `<tag>..main == 0`): a
# full-surface baseline tag is cut ONCE and `main` legitimately advances past it as later phases land
# build-config/removal commits (at Phase-0 completion faBolus `main` is already 6 commits ahead of the
# tag). Requiring `<tag>..main == 0` (main == tag tip) would therefore red-flag every phase after the
# tag was cut. The invariant that actually matters — and that catches the real staleness/divergence
# failure mode the 08-18 tag exhibited — is `main..<tag> == 0` (main is not BEHIND the tag) plus the
# ancestor + annotated checks. `<tag>..main` (how far main has advanced) is reported informationally.
#
# Read-only. Uses local sibling clones (../TandemKit, ../faBolusGarmin); no network, no `gh` dependency.
# Every later removal phase runs this UNCHANGED as part of the exit gate.
#
# Usage:  scripts/verify-pre-narrow-tags.sh [TAG]        (default TAG: pre-narrow/2026-08-20)
set -uo pipefail

TAG="${1:-${PRE_NARROW_TAG:-pre-narrow/2026-08-20}}"
FABOLUS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# repo-name : path (relative to the faBolus repo root's parent for the siblings)
declare -a REPOS=(
  "faBolus:$FABOLUS_ROOT"
  "TandemKit:$FABOLUS_ROOT/../TandemKit"
  "faBolusGarmin:$FABOLUS_ROOT/../faBolusGarmin"
)

fail=0
printf '== verify-pre-narrow-tags.sh — baseline tag: %s ==\n' "$TAG"

for entry in "${REPOS[@]}"; do
  name="${entry%%:*}"
  dir="${entry#*:}"

  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    printf '  ✗ %-14s NO local clone at %s (cannot verify)\n' "$name" "$dir"
    fail=1
    continue
  fi

  # (1) tag exists + is annotated
  otype="$(git -C "$dir" cat-file -t "$TAG" 2>/dev/null || echo missing)"
  if [ "$otype" = "missing" ]; then
    printf '  ✗ %-14s tag %s NOT PRESENT\n' "$name" "$TAG"
    fail=1
    continue
  fi
  if [ "$otype" != "tag" ]; then
    printf '  ✗ %-14s tag %s is LIGHTWEIGHT (%s), expected annotated\n' "$name" "$TAG" "$otype"
    fail=1
    continue
  fi

  # (2) ancestor of main
  if ! git -C "$dir" merge-base --is-ancestor "$TAG" main 2>/dev/null; then
    printf '  ✗ %-14s tag %s is NOT an ancestor of main (baseline orphaned/diverged)\n' "$name" "$TAG"
    fail=1
    continue
  fi

  # (3) main not behind the tag
  behind="$(git -C "$dir" rev-list --count "main..$TAG" 2>/dev/null || echo '?')"
  ahead="$(git -C "$dir" rev-list --count "$TAG..main" 2>/dev/null || echo '?')"
  if [ "$behind" != "0" ]; then
    printf '  ✗ %-14s main is BEHIND %s by %s commit(s) — baseline diverged\n' "$name" "$TAG" "$behind"
    fail=1
    continue
  fi

  printf '  ✓ %-14s annotated, ancestor of main, main not behind (main +%s ahead of baseline)\n' \
    "$name" "$ahead"
done

if [ "$fail" -ne 0 ]; then
  echo "❌ pre-narrow baseline tag check FAILED"
  exit 1
fi
echo "✅ pre-narrow baseline tag current + annotated on all 3 repos"
