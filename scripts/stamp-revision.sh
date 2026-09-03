#!/usr/bin/env bash
#
# Writes ios/faBolus/Generated/AppRevision.swift — the short commit hash the diagnostics export and the
# Debug menu both display, so a reader can tell which binary produced a given export.
#
# WHY A GENERATED FILE AND NOT A MAINTAINED CONSTANT
# ---------------------------------------------------
# A hand-maintained answer is worse than no answer: the day somebody forgets to bump it, two different
# builds claim the same identity and the value starts lying instead of merely being absent. So the value
# is derived from git at build time, never typed by a person.
#
# WHY THE VALUE CANNOT LIVE IN COMMITTED SOURCE
# ----------------------------------------------
# This is arithmetic, not preference. A commit's hash is a function of its own contents, so storing
# HEAD's hash inside that same commit is a fixed point nothing can compute. Any committed hash can only
# ever be an EARLIER commit's — permanently stale by at least one, which is exactly the failure this
# script exists to remove. So the output is git-ignored (ios/faBolus/Generated/.gitignore) and rewritten
# on every build; scripts/check-version-sync.sh asserts it never becomes tracked.
#
# HONESTY RULES
#   * Uncommitted changes mean the hash alone would misdescribe the tree — DIRTY renders true and the
#     caller appends a trailing "+".
#   * Outside a git checkout the revision is genuinely unknown, so the stamp says "unknown" rather than
#     guessing. "unknown" contains no hex-only characters, so it can never be mistaken for a real hash.
#
#   ./scripts/stamp-revision.sh            # write the stamp (idempotent; every build script calls this)
#   ./scripts/stamp-revision.sh --check    # verify the stamp on disk describes THIS tree; never writes
#
# --check runs the IDENTICAL derivation as the write path so scripts/check-version-sync.sh can assert
# freshness without a second copy of the logic — generator and guard cannot drift apart.
#
# THE ONE RESIDUAL THE CHECK DOES NOT CATCH: committing, then rebuilding straight from Xcode without
# re-running scripts/generate-project.sh. The tree is clean at that point so no "+" renders, and the
# stamp keeps naming the previous commit. This is narrower here than it sounds: the generated
# .xcodeproj is itself git-ignored, so no fresh clone can produce a buildable project without going
# through generate-project.sh first, and that script always stamps before it generates. The residual
# case is real but requires an existing, already-generated project left open in the IDE. Stated plainly
# because an inaccurate stamp is worse than none, and silently accepting it was never on the table.
#
# Exit codes: 0 = stamped / fresh (or skipped)   1 = stale   2 = bad invocation
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="ios/faBolus/Generated/AppRevision.swift"
UNKNOWN="unknown"

MODE="write"
case "${1:-}" in
  "")       MODE="write" ;;
  --check)  MODE="check" ;;
  *)        echo "usage: $0 [--check]"; exit 2 ;;
esac

if [ ! -d ios/faBolus ]; then
  echo "ios/faBolus not found — this script must run from the faBolus repo."
  exit 2
fi

# Fixed-width by construction: `git rev-parse --short` may LENGTHEN its output to keep the
# abbreviation unique, which would quietly widen the value. Cutting the full hash pins the width; this
# is a debugging pointer, not a uniqueness proof, so the shortening is not a real hazard.
short="$UNKNOWN"
dirty="false"
if git rev-parse --git-dir >/dev/null 2>&1; then
  if full="$(git rev-parse HEAD 2>/dev/null)"; then
    short="$(printf '%s' "$full" | cut -c1-7)"
    # Untracked files count as dirty on purpose: an untracked .swift file dropped under ios/faBolus
    # compiles into the binary via the recursive source path, so the hash alone would not describe
    # what shipped. Build products are already excluded by .gitignore, and the generated stamp
    # excludes itself, so a genuinely clean tree still reports clean.
    if [ -n "$(git status --porcelain)" ]; then
      dirty="true"
    fi
  fi
fi

mkdir -p "$(dirname "$OUT")"

# Written to a sibling temp file and moved into place so an interrupted run cannot leave a half-file
# that fails to compile, and so an unchanged stamp keeps its mtime (no needless rebuild churn).
tmp="$OUT.tmp"
trap 'rm -f "$tmp"' EXIT
{
  cat <<'HEADER'
// GENERATED FILE — do not edit, and do not commit it (ios/faBolus/Generated is git-ignored).
//
// Rewritten by scripts/stamp-revision.sh immediately before every generate/build, so the diagnostics
// export and the Debug menu name the exact tree the binary was built from with nobody having to
// remember anything. See that script for why the value cannot live in committed source.
HEADER
  printf 'enum AppRevision {\n\n'
  printf '    /// Seven leading hex characters of the build commit, or "unknown" outside a git checkout.\n'
  printf '    static let short = "%s"\n\n' "$short"
  printf '    /// True when the build tree carried uncommitted changes, so `short` alone would misdescribe it.\n'
  printf '    static let dirty = %s\n' "$dirty"
  printf '}\n'
} > "$tmp"

# Spelled out as an if rather than folded into the assignment: under `set -e` a command substitution
# that exits nonzero takes the whole assignment — and the script — down with it. That failure would be
# invisible precisely on a CLEAN tree, i.e. on a release build.
rendered="$short"
if [ "$dirty" = true ]; then
  rendered="$short+"
fi

if [ "$MODE" = "check" ]; then
  # Absent is reported loudly rather than failed: nothing has been built in this tree yet, so there is
  # no stamp to be wrong about, and the compile itself fails closed on the missing `AppRevision` symbol
  # if anyone tries. A PRESENT-but-stale stamp is the dangerous case — that is a binary whose diagnostics
  # name the wrong tree.
  if [ ! -f "$OUT" ]; then
    rm -f "$tmp"
    echo "SKIPPED the revision-stamp check: no $OUT (nothing has been built in this tree)."
    echo "  A build cannot silently skip it — compiling without the stamp fails on an undefined"
    echo "  'AppRevision' symbol. Every build path here runs the generator first."
    exit 0
  fi
  if cmp -s "$tmp" "$OUT"; then
    rm -f "$tmp"
    echo "revision stamp is fresh: $rendered"
    exit 0
  fi
  rm -f "$tmp"
  echo "DRIFT: $OUT does not describe this tree (expected $rendered)."
  echo "  The last build here was made from a different commit or a differently-dirty tree, so its"
  echo "  diagnostics name the wrong one. Fix: ./scripts/stamp-revision.sh (or re-run"
  echo "  ./scripts/generate-project.sh, which stamps before it generates)."
  exit 1
fi

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
  echo "revision stamp unchanged: $rendered"
else
  mv "$tmp" "$OUT"
  echo "stamped $OUT: $rendered"
fi
