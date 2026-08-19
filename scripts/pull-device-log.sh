#!/usr/bin/env bash
# pull-device-log.sh — headless, sudo-free capture of a connected iPhone's unified (os_log) log.
#
# WHY THIS EXISTS
#   On-device pump/CGM diagnostics need the phone's os_log filtered to `subsystem == "com.fabolus.app"`.
#   The obvious command, `sudo log collect --device-udid …`, fails with
#       log: failed to create archive: Device not configured (6)      # POSIX ENXIO
#   whenever it is handed the CoreDevice *identifier* that `xcrun devicectl list devices` prints (a
#   host-generated 8-4-4-4-12 UUID, e.g. 044EDF18-CC73-5CBB-9E6C-127BB38781ED). `--device-udid`
#   resolves devices through the lockdown/usbmux namespace, which is keyed on the HARDWARE UDID
#   (e.g. 00008110-00053454016B801E) — a namespace where the CoreDevice UUID simply does not exist.
#   ENXIO is just "no such device". Root, unlocking the phone, and priming with Console.app all leave
#   it failing, which is what makes it look like an iOS-26 platform regression. It is not.
#
#   This script sidesteps `log collect` entirely: iOS 26 still exposes `com.apple.os_trace_relay`
#   over plain usbmux, which needs NO sudo and NO CoreDevice tunnel. Verified on iPhone 13 Pro /
#   iOS 26.6 with Xcode 26.6: a 6-hour window pulled in ~26s and yielded 1109 `[com.fabolus.app:ble]`
#   entries, full subsystem/category metadata intact.
#
#   To keep the original mistake from recurring, this script auto-resolves the hardware UDID and
#   REJECTS a CoreDevice-identifier-shaped --udid with a pointed error.
#
# MODES
#   archive (default)  Pull a time window as a .logarchive, then run `/usr/bin/log show` with a real
#                      NSPredicate. High fidelity: levels, subsystem, category, full metadata.
#   --live             Stream matching lines in real time. Use this while REPRODUCING a bug: os_log
#                      debug/info messages are ring-buffered in memory on the device and can age out
#                      before an archive pull sees them. Filtering here is substring matching on the
#                      whole rendered line, not a true predicate — so lines from OTHER processes that
#                      merely mention the bundle id (e.g. runningboardd assertions) also match. Use
#                      archive mode when you need an exact `subsystem ==` predicate.
#
# USAGE
#   scripts/pull-device-log.sh                             # last 15 min of com.fabolus.app -> archive + filtered text
#   scripts/pull-device-log.sh --minutes 60                # wider retrospective window
#   scripts/pull-device-log.sh --category ble              # narrow to the BLE/pump wire trace
#   scripts/pull-device-log.sh --subsystem com.apple.bluetooth --category '' --minutes 30
#   scripts/pull-device-log.sh --live                      # live stream (Ctrl-C to stop)
#   scripts/pull-device-log.sh --live --out /tmp/ble.log   # live stream, also tee'd to a file
#   scripts/pull-device-log.sh --all                       # no subsystem filter (whole device log)
#   scripts/pull-device-log.sh --list-devices              # show hardware UDIDs of attached devices
#   scripts/pull-device-log.sh --keep-archive              # don't delete the .logarchive afterwards
#
# REQUIREMENTS
#   - Device connected by USB, unlocked, and already trusted/paired with this Mac (Xcode-normal).
#   - `uv` on PATH (Homebrew: `brew install uv`). pymobiledevice3 is run via `uvx`, so nothing is
#     installed globally and nothing is added to the repo's dependencies. If `pymobiledevice3` is
#     already on PATH, that is used directly instead.
#   - No sudo. If something here asks for a password, the invocation is wrong.
#
# FALLBACK (GUI) — if this script cannot reach the device at all
#   Console.app: open Console, select the iPhone in the left sidebar, click Start, then put
#   `subsystem:com.fabolus.app` (optionally `category:ble`) in the search field. Action > "Include
#   Info Messages" and "Include Debug Messages" must be enabled or Logger.debug lines are hidden.
#   Save via File > Export. This works but is not scriptable, which is the whole reason for the above.
#
# NOT USEFUL, for the record (all tested on iOS 26.6, 2026-08-19):
#   - `log stream --device-udid …`   -> no such option; `log(1)` has device modes only on `collect`.
#   - `devicectl device sysdiagnose` -> fails instantly with `DiagnoseError 0` (not a storage issue);
#                                       undiagnosed, and unnecessary now.
#   - `devicectl` has no os_log/unified-log subcommand of any kind.
set -euo pipefail

# NOTE: call /usr/bin/log by absolute path — a zsh function shadows `log` in this project's shells.
LOG_BIN="/usr/bin/log"

SUBSYSTEM="com.fabolus.app"
CATEGORY=""
MINUTES=15
UDID=""
OUT_DIR="${TMPDIR:-/tmp}"; OUT_DIR="${OUT_DIR%/}/fabolus-device-logs"
OUT_FILE=""
LIVE=0
KEEP_ARCHIVE=0
LIST_ONLY=0
ALL=0

die() { printf '❌ %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*" >&2; }

usage() { sed -n '2,/^set -euo pipefail$/p' "$0" | sed 's/^# \{0,1\}//;$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --subsystem)   SUBSYSTEM="${2-}"; shift 2 ;;
    --category)    CATEGORY="${2-}"; shift 2 ;;
    --minutes|-m)  MINUTES="${2-}"; shift 2 ;;
    --udid)        UDID="${2-}"; shift 2 ;;
    --out|-o)      OUT_FILE="${2-}"; shift 2 ;;
    --out-dir)     OUT_DIR="${2-}"; shift 2 ;;
    --live)        LIVE=1; shift ;;
    --all)         ALL=1; SUBSYSTEM=""; CATEGORY=""; shift ;;
    --keep-archive) KEEP_ARCHIVE=1; shift ;;
    --list-devices) LIST_ONLY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# pymobiledevice3 runner: prefer an installed binary, else uvx (cached, no global install).
# ---------------------------------------------------------------------------
if command -v pymobiledevice3 >/dev/null 2>&1; then
  pmd3() { pymobiledevice3 "$@"; }
elif command -v uvx >/dev/null 2>&1; then
  pmd3() { uvx --quiet --from pymobiledevice3 pymobiledevice3 "$@"; }
elif command -v uv >/dev/null 2>&1; then
  pmd3() { uv tool run --quiet --from pymobiledevice3 pymobiledevice3 "$@"; }
else
  die "need either 'pymobiledevice3' or 'uv' on PATH. Install with: brew install uv"
fi

# ---------------------------------------------------------------------------
# Device resolution. This is the guardrail against the root cause of this script's existence:
# a CoreDevice identifier must never reach --device-udid-style lookups.
# ---------------------------------------------------------------------------
COREDEVICE_UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

# Validate the window up front, before touching the device, so a typo fails fast.
if [ "$LIVE" = 0 ] && [ "$LIST_ONLY" = 0 ]; then
  case "$MINUTES" in
    ''|*[!0-9]*) die "--minutes must be a positive integer (got '$MINUTES')" ;;
  esac
  [ "$MINUTES" -gt 0 ] || die "--minutes must be > 0"
fi

list_devices_json() { pmd3 usbmux list 2>/dev/null; }

if [ "$LIST_ONLY" = 1 ]; then
  printf '📱 Attached devices (hardware UDIDs — these are what this script and log(1) want):\n'
  list_devices_json | python3 -c '
import json,sys
try: devs = json.load(sys.stdin)
except Exception: devs = []
seen=set()
for d in devs:
    u=d.get("UniqueDeviceID")
    if not u or u in seen: continue
    seen.add(u)
    print(f'"'"'  {u}  {d.get("DeviceName","?")}  ({d.get("ProductType","?")}, iOS {d.get("ProductVersion","?")}, {d.get("ConnectionType","?")})'"'"')
if not seen: print("  (none — is the phone plugged in, unlocked, and trusted?)")
'
  printf '\nFor contrast, `xcrun devicectl list devices` prints CoreDevice identifiers (8-4-4-4-12\nUUIDs). Those are NOT usable here or with `log collect --device-udid`.\n'
  exit 0
fi

if [ -n "$UDID" ]; then
  if [[ "$UDID" =~ $COREDEVICE_UUID_RE ]]; then
    die "'$UDID' is a CoreDevice identifier (the UUID from \`xcrun devicectl list devices\`), not a
   hardware UDID. That mismatch is exactly what makes \`log collect --device-udid\` fail with
   \"Device not configured (6)\". Run: $0 --list-devices"
  fi
fi

DEVICES_JSON="$(list_devices_json || true)"
RESOLVED="$(printf '%s' "$DEVICES_JSON" | python3 -c '
import json,sys
want = sys.argv[1] if len(sys.argv)>1 else ""
try: devs = json.load(sys.stdin)
except Exception: devs = []
# Prefer USB over Network for a stable, fast relay.
devs.sort(key=lambda d: 0 if d.get("ConnectionType")=="USB" else 1)
for d in devs:
    u = d.get("UniqueDeviceID")
    if not u: continue
    if want and u != want: continue
    print("\t".join([u, d.get("DeviceName","?"), d.get("ProductType","?"), d.get("ProductVersion","?")]))
    break
' "$UDID" 2>/dev/null || true)"

if [ -z "$RESOLVED" ]; then
  if [ -n "$UDID" ]; then
    die "UDID '$UDID' is not among the attached devices. Run: $0 --list-devices"
  fi
  die "no attached device found over usbmux. Check: cable seated, phone unlocked, 'Trust This
   Computer' accepted. Then: $0 --list-devices"
fi

UDID="$(printf '%s' "$RESOLVED" | cut -f1)"
DEV_NAME="$(printf '%s' "$RESOLVED" | cut -f2)"
DEV_MODEL="$(printf '%s' "$RESOLVED" | cut -f3)"
DEV_OS="$(printf '%s' "$RESOLVED" | cut -f4)"

printf '📱 %s (%s, iOS %s)\n' "$DEV_NAME" "$DEV_MODEL" "$DEV_OS" >&2
printf '   hardware UDID: %s\n' "$UDID" >&2

# ---------------------------------------------------------------------------
# LIVE mode
# ---------------------------------------------------------------------------
if [ "$LIVE" = 1 ]; then
  set -- syslog live --udid "$UDID" --label
  if [ -n "$SUBSYSTEM" ]; then set -- "$@" --match "$SUBSYSTEM"; fi
  if [ -n "$CATEGORY" ]; then set -- "$@" --match "$CATEGORY"; fi
  if [ -n "$OUT_FILE" ]; then set -- "$@" --out "$OUT_FILE"; fi

  if [ "$ALL" = 1 ]; then
    info "live stream: ALL subsystems"
  else
    info "live stream: matching '$SUBSYSTEM'${CATEGORY:+ AND '$CATEGORY'} (substring match on the rendered line)"
  fi
  [ -n "$OUT_FILE" ] && info "also writing: $OUT_FILE"
  info "Ctrl-C to stop. Reproduce the bug NOW — this is the capture that survives debug-level ring-buffer aging."
  printf '\n' >&2
  # NOTE: plain call, not `exec` — pmd3 is a shell function and `exec` only takes external commands.
  pmd3 "$@"
  exit $?
fi

# ---------------------------------------------------------------------------
# ARCHIVE mode
# ---------------------------------------------------------------------------
case "$MINUTES" in
  ''|*[!0-9]*) die "--minutes must be a positive integer (got '$MINUTES')" ;;
esac
[ "$MINUTES" -gt 0 ] || die "--minutes must be > 0"

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/device-$STAMP.logarchive"
TEXT="${OUT_FILE:-$OUT_DIR/device-$STAMP.log}"
START_TS="$(python3 -c "import time,sys; print(int(time.time() - 60*int(sys.argv[1])))" "$MINUTES")"

mkdir -p "$ARCHIVE"   # pymobiledevice3 wants an existing dir; the .logarchive suffix makes log(1) accept it
info "collecting last ${MINUTES}m into $(basename "$ARCHIVE") ..."
if ! pmd3 syslog collect --udid "$UDID" --start-time "$START_TS" "$ARCHIVE" >&2; then
  rm -rf "$ARCHIVE"
  die "syslog collect failed. If the device just reconnected, retry; otherwise fall back to
   Console.app (see the FALLBACK section in --help)."
fi

if [ ! -f "$ARCHIVE/Info.plist" ]; then
  rm -rf "$ARCHIVE"
  die "collected archive looks malformed (no Info.plist). Retry, or use the Console.app fallback."
fi
info "archive: $(du -sh "$ARCHIVE" | cut -f1)"

# Build the real NSPredicate. Empty subsystem (--all) means no filtering.
PREDICATE=""
if [ -n "$SUBSYSTEM" ]; then
  PREDICATE="subsystem == \"$SUBSYSTEM\""
  [ -n "$CATEGORY" ] && PREDICATE="$PREDICATE AND category == \"$CATEGORY\""
fi

if [ -n "$PREDICATE" ]; then
  info "filtering: $PREDICATE"
  "$LOG_BIN" show --archive "$ARCHIVE" --predicate "$PREDICATE" --info --debug --style compact >"$TEXT"
else
  info "filtering: (none — full device log)"
  "$LOG_BIN" show --archive "$ARCHIVE" --info --debug --style compact >"$TEXT"
fi

# Line 1 of `log show` output is the column header; entries are everything after it.
TOTAL_LINES="$(wc -l <"$TEXT" | tr -d ' ')"
ENTRIES=$(( TOTAL_LINES > 0 ? TOTAL_LINES - 1 : 0 ))

printf '\n✅ %s matching entries → %s\n' "$ENTRIES" "$TEXT" >&2
if [ "$ENTRIES" -eq 0 ]; then
  printf '\n⚠️  Zero entries. Most likely causes, in order:\n' >&2
  printf '   1. The app was not running/logging during the last %sm — widen with --minutes, or use --live.\n' "$MINUTES" >&2
  printf '   2. Debug-level messages already aged out of the device ring buffer — use --live while reproducing.\n' >&2
  printf '   3. Subsystem/category typo. Sanity-check the archive with:\n' >&2
  printf "      %s show --archive '%s' --predicate 'subsystem CONTAINS[c] \"fabolus\"' --info --debug\n" "$LOG_BIN" "$ARCHIVE" >&2
  KEEP_ARCHIVE=1   # keep it so the above sanity check is actually runnable
fi

if [ "$KEEP_ARCHIVE" = 1 ]; then
  printf '   archive kept: %s\n' "$ARCHIVE" >&2
  printf '   re-query with a different predicate, or open it in Console.app:  open %s\n' "$ARCHIVE" >&2
else
  rm -rf "$ARCHIVE"
  printf '   (archive discarded; pass --keep-archive to retain it for re-querying)\n' >&2
fi
