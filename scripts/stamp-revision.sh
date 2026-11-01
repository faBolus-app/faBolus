#!/usr/bin/env bash
# Writes ios/faBolus/Generated/AppRevision.swift: the commit this build came from, for the diagnostics
# export, with "+" when the tree has uncommitted changes and "unknown" outside a git checkout. The file is
# gitignored: a commit can't contain its own hash.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="ios/faBolus/Generated/AppRevision.swift"
mkdir -p "$(dirname "$OUT")"
if REV="$(git rev-parse --short=10 HEAD 2>/dev/null)"; then
  git diff --quiet HEAD -- 2>/dev/null || REV="$REV+"
else
  REV="unknown"
fi
NEW="// Written by scripts/stamp-revision.sh; not committed.
enum AppRevision {
    static let commit = \"$REV\"
}"
[ -f "$OUT" ] && [ "$(cat "$OUT")" = "$NEW" ] || printf '%s\n' "$NEW" >"$OUT"
