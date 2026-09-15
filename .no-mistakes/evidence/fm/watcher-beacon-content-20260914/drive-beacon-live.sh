#!/usr/bin/env bash
# Live drive of the watcher liveness beacon (state/.last-watcher-beat) against a
# real armed watcher in a throwaway FM_HOME.
# Usage: ROOT=<checkout under test> MODE=full|repro drive-beacon-live.sh
#   full   - arm, inspect beacon across polls, run every reader against a
#            non-empty fresh, non-empty stale, and zero-byte fresh beacon
#   repro  - arm and inspect the beacon only (used against the base commit)
set -u
ROOT=${ROOT:?set ROOT to the checkout under test}
MODE=${MODE:-full}
T=$(mktemp -d "${TMPDIR:-/tmp}/beacon-live.XXXXXX")
H=$T/home
S=$H/state
FB=$T/fakebin
mkdir -p "$S" "$H/config" "$T/root" "$FB"
# The watcher must not touch a real terminal multiplexer.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"
chmod +x "$FB/tmux"
BEAT=$S/.last-watcher-beat
LIB=$ROOT/bin/fm-wake-lib.sh
SUP=$ROOT/bin/fm-supervision-lib.sh
WATCH=$ROOT/bin/fm-watch.sh
export PATH="$FB:$PATH" FM_HOME="$H" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=60 \
  FM_SUPERVISION_MODEL=persistent FM_ARM_ATTACH_POLL=0.2
WPID=
ARM1=
ARM2=

cleanup() {
  [ -n "$WPID" ] && kill -CONT "$WPID" 2>/dev/null
  [ -n "$ARM2" ] && kill "$ARM2" 2>/dev/null
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  [ -n "$ARM1" ] && kill "$ARM1" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
age() { bash -c '. "$1"; fm_path_age "$2"' _ "$LIB" "$BEAT"; }
show_beacon() {
  printf 'beacon: size=%s bytes, mtime age=%ss, content=' "$(wc -c < "$BEAT" | tr -d ' ')" "$(age)"
  if [ -s "$BEAT" ]; then cat "$BEAT"; else printf '(empty)\n'; fi
}
size_observer() {
  if [ -s "$BEAT" ]; then echo "size-based outside observer: UP (file non-empty)"
  else echo "size-based outside observer: DOWN (file is zero bytes)"; fi
}
healthy() {
  if bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 60 "$4"' _ "$LIB" "$S" "$WATCH" "$H"; then
    echo "fm_watcher_healthy (turn-end guard / arm primitive): HEALTHY"
  else
    echo "fm_watcher_healthy (turn-end guard / arm primitive): NOT HEALTHY"
  fi
}
supfresh() {
  bash -c '. "$1"; fm_supervision_status "$2" 60
    printf "fm_supervision_status: FM_SUP_WATCHER_FRESH=%s (last beat %s)\n" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_BEACON_DESC"' _ "$SUP" "$S"
}
guard() {
  local out
  out=$(FM_ROOT_OVERRIDE="$T/root" "$ROOT/bin/fm-guard.sh" 2>&1)
  if [ -z "$out" ]; then echo "bin/fm-guard.sh: (silent - supervision healthy)"
  else printf 'bin/fm-guard.sh output:\n%s\n' "$out"; fi
}

step "Arm the watcher the way an operator does: bin/fm-watch-arm.sh"
"$ROOT/bin/fm-watch-arm.sh" > "$T/arm1.out" 2>&1 &
ARM1=$!
i=0
while [ "$i" -lt 150 ] && ! grep -q '^watcher: ' "$T/arm1.out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
cat "$T/arm1.out"
WPID=$(cat "$S/.watch.lock/pid" 2>/dev/null || true)
echo "lock holder pid=$WPID (alive: $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no))"

step "Inspect the beacon a live watcher left"
show_beacon
size_observer
healthy

if [ "$MODE" = repro ]; then
  exit 0
fi

step "Wait across two more polls: content and mtime both advance"
first=$(cat "$BEAT")
sleep 2.2
show_beacon
second=$(cat "$BEAT")
printf 'content changed across polls: %s\n' "$([ "$first" != "$second" ] && echo yes || echo no)"
printf 'content pid matches lock holder: %s\n' "$(grep -q "pid=$WPID\$" "$BEAT" && echo yes || echo no)"

step "mtime readers against the running watcher's non-empty fresh beacon"
healthy
supfresh
"$ROOT/bin/fm-watch-arm.sh" > "$T/arm2.out" 2>&1 &
ARM2=$!
i=0
while [ "$i" -lt 100 ] && ! grep -q '^watcher: ' "$T/arm2.out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
printf 'second bin/fm-watch-arm.sh: %s\n' "$(head -1 "$T/arm2.out")"
kill "$ARM2" 2>/dev/null
wait "$ARM2" 2>/dev/null
ARM2=
echo "watcher still alive after detaching the second arm: $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"

step "Freeze the watcher (SIGSTOP keeps the pid alive) and put a task in flight"
kill -STOP "$WPID"
printf 'window=firstmate:fm-task\nkind=ship\n' > "$S/task.meta"
show_beacon
guard

step "ADVERSARIAL: non-empty content but an old mtime must read DOWN"
printf 'stale informational line pid=%s\n' "$WPID" > "$BEAT"
touch -m -d '2000-01-01' "$BEAT"
show_beacon
size_observer
healthy
supfresh
guard
echo "--- bin/fm-watch-arm.sh against the live-but-stale holder (confirm timeout 3s):"
FM_ARM_CONFIRM_TIMEOUT=3 timeout 40 "$ROOT/bin/fm-watch-arm.sh" 2>&1 | sed -n '1,4p'
echo "arm exit=${PIPESTATUS[0]}"

step "ADVERSARIAL: a zero-byte file with a fresh mtime must still read HEALTHY"
rm -f "$S/.guard-watcher-stale-banner"
: > "$BEAT"
show_beacon
size_observer
healthy
supfresh
guard

step "Resume the watcher: its next poll restores non-empty content and a fresh mtime"
rm -f "$S/task.meta"
kill -CONT "$WPID"
sleep 2.2
show_beacon
size_observer
healthy
