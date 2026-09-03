#!/usr/bin/env bash
# Run the independent local verification suites CONCURRENTLY instead of serially, so a full local
# check is ~max(job) instead of ~sum(job). The three jobs touch disjoint toolchains/dirs (SwiftPM
# `.build/`, Python/grep, xcodebuild DerivedData), so running them at once is safe and does NOT change
# any suite's INTERNAL parallelism — it adds no new flake surface.
#
# Usage:
#   scripts/test-all.sh                  # all three: packages + schema + ios
#   scripts/test-all.sh packages schema  # a subset (names: packages | schema | ios)
#
# Exit code is non-zero if ANY selected job failed; the failing jobs' logs are tailed at the end. This
# is a developer convenience — CI still runs the jobs as separate, independently-attributable steps, so
# a green here is not a substitute for CI.
set -uo pipefail
cd "$(dirname "$0")/.."

JOBS=("$@")
[ "$#" -eq 0 ] && JOBS=(packages schema ios)

LOGDIR="$(mktemp -d)"
names=()
pids=()
logs=()

start() {  # start <name> <command...>
    local name="$1"; shift
    local log="$LOGDIR/$name.log"
    ( "$@" ) >"$log" 2>&1 &
    names+=("$name"); pids+=("$!"); logs+=("$log")
    echo "▶︎ started $name (pid $!) → $log"
}

# All three local Swift packages (faBolusCore, HistoryStore, faBolusDesign) run here as one job, so
# none of them is left unrun locally. CI still runs each as its own separately-attributable step.
run_packages() {
    swift test --package-path Packages/faBolusCore \
        && swift test --package-path Packages/HistoryStore \
        && swift test --package-path Packages/faBolusDesign
}

for job in "${JOBS[@]}"; do
    case "$job" in
        packages) start packages run_packages ;;
        schema)   start schema   ./scripts/check-schema-drift.sh ;;
        ios)      start ios      ./scripts/test-ios.sh ;;
        *) echo "unknown job: $job (want: packages | schema | ios)"; exit 2 ;;
    esac
done

fail=0
failed_idx=()
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "✅ ${names[$i]} passed"
    else
        echo "❌ ${names[$i]} FAILED"
        fail=1
        failed_idx+=("$i")
    fi
done

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "=================== failing job output (tail) ==================="
    for i in "${failed_idx[@]}"; do
        echo "--- ${names[$i]} (${logs[$i]}) ---"
        tail -n 30 "${logs[$i]}"
        echo ""
    done
    exit 1
fi

echo ""
echo "✅ all selected suites passed (ran in parallel; logs in $LOGDIR)"
