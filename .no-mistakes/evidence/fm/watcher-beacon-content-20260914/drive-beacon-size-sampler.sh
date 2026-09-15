#!/usr/bin/env bash
# ADVERSARIAL live drive: a size-based outside observer samples the beacon as
# fast as it can while a real watcher rewrites it on a very short poll. Counts
# how many distinct beacon writes it saw and how many samples read zero bytes.
# Usage: ROOT=<checkout under test> SECONDS_TO_SAMPLE=20 drive-beacon-size-sampler.sh
set -u
ROOT=${ROOT:?set ROOT to the checkout under test}
DURATION=${SECONDS_TO_SAMPLE:-20}
T=$(mktemp -d "${TMPDIR:-/tmp}/beacon-sampler.XXXXXX")
H=$T/home
S=$H/state
FB=$T/fakebin
mkdir -p "$S" "$H/config" "$FB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"
chmod +x "$FB/tmux"
export PATH="$FB:$PATH" FM_HOME="$H" FM_POLL=0.05 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_GUARD_GRACE=60
"$ROOT/bin/fm-watch-arm.sh" > "$T/arm.out" 2>&1 &
ARM=$!
cleanup() {
  local pid
  pid=$(cat "$S/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  kill "$ARM" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
i=0
while [ "$i" -lt 150 ] && ! grep -q '^watcher: ' "$T/arm.out" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
printf 'arm: %s\n' "$(head -1 "$T/arm.out")"
printf 'watcher poll: FM_POLL=%s, sampling for %ss\n' "$FM_POLL" "$DURATION"
python3 - "$S/.last-watcher-beat" "$DURATION" <<'PY'
import os, sys, time
path, duration = sys.argv[1], float(sys.argv[2])
end = time.monotonic() + duration
samples = zero = missing = writes = 0
last_mtime = None
while time.monotonic() < end:
    try:
        st = os.stat(path)
    except FileNotFoundError:
        missing += 1
        continue
    samples += 1
    if st.st_size == 0:
        zero += 1
    if st.st_mtime_ns != last_mtime:
        writes += 1
        last_mtime = st.st_mtime_ns
print(f"samples={samples} distinct_beacon_writes_seen={writes} zero_byte_samples={zero} missing_samples={missing}")
print("size-based observer verdict: " + ("NEVER saw a zero-byte beacon" if zero == 0 else f"saw a zero-byte beacon {zero} time(s)"))
PY
printf 'watcher alive at end: %s\n' "$(kill -0 "$(cat "$S/.watch.lock/pid" 2>/dev/null)" 2>/dev/null && echo yes || echo no)"
